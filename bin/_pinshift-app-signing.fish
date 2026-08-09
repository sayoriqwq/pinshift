function pinshift_decode_mobileprovision --argument-names source destination
    if not test -f "$source"; or test -L "$source"
        return 1
    end

    security cms -D -i "$source" >"$destination" 2>/dev/null
    or return $status
    chmod 600 "$destination"
end

function pinshift_plist_raw --argument-names plist key_path
    plutil -extract "$key_path" raw "$plist" 2>/dev/null
end

function pinshift_decoded_profile_is_ios_app --argument-names profile bundle_identifier
    set --local prefix (pinshift_plist_raw "$profile" ApplicationIdentifierPrefix.0)
    or return 1
    set --local application_identifier (
        pinshift_plist_raw "$profile" Entitlements.application-identifier
    )
    or return 1

    if test "$application_identifier" != "$prefix.$bundle_identifier"
        return 1
    end

    plutil -extract Platform json -o - "$profile" 2>/dev/null |
        jq --exit-status 'type == "array" and (index("iOS") != null)' >/dev/null
end

function pinshift_iso8601_epoch --argument-names timestamp
    /usr/bin/env TZ=UTC /bin/date -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" '+%s' 2>/dev/null
end

function pinshift_local_expiration --argument-names epoch
    /bin/date -r "$epoch" '+%Y-%m-%d %H:%M:%S %Z'
end

function pinshift_resign_restore_profiles
    if not set --query _pinshift_resign_moved_sources
        return 0
    end

    set --local restore_status 0
    set --local index 1
    while test $index -le (count $_pinshift_resign_moved_sources)
        set --local source_path $_pinshift_resign_moved_sources[$index]
        set --local backup_path $_pinshift_resign_moved_backups[$index]

        if not test -e "$backup_path"
            set index (math $index + 1)
            continue
        end
        if test -e "$source_path"
            echo "A provisioning profile path was recreated during rollback; its backup was preserved." >&2
            set restore_status 1
            set index (math $index + 1)
            continue
        end

        mv "$backup_path" "$source_path"
        or set restore_status $status
        set index (math $index + 1)
    end

    return $restore_status
end

function pinshift_resign_archive_new_profiles
    if not set --query _pinshift_resign_profile_directories \
            _pinshift_resign_bundle_identifier \
            _pinshift_resign_backup_directory \
            _pinshift_resign_staging_root
        return 0
    end

    set --local archive_status 0
    set --local archive_index 0
    for profile_directory in $_pinshift_resign_profile_directories
        if not test -d "$profile_directory"; or test -L "$profile_directory"
            continue
        end

        set --local current_profiles (
            find "$profile_directory" -maxdepth 1 -name '*.mobileprovision'
        )
        or begin
            set archive_status 1
            continue
        end

        for profile in $current_profiles
            if test -L "$profile"
                set archive_status 1
                continue
            end
            if not test -f "$profile"
                continue
            end

            set archive_index (math $archive_index + 1)
            set --local decoded \
                "$_pinshift_resign_staging_root/cleanup-profile-$archive_index.plist"
            pinshift_decode_mobileprovision "$profile" "$decoded"
            or begin
                set archive_status 1
                continue
            end
            if not pinshift_decoded_profile_is_ios_app \
                    "$decoded" "$_pinshift_resign_bundle_identifier"
                continue
            end

            set --local backup_path \
                "$_pinshift_resign_backup_directory/generated-$archive_index-"(path basename "$profile")
            mv "$profile" "$backup_path"
            or set archive_status $status
        end
    end

    return $archive_status
end

function pinshift_resign_cleanup --on-event fish_exit
    if set --query _pinshift_resign_profiles_committed
        if test "$_pinshift_resign_profiles_committed" != 1
            pinshift_resign_archive_new_profiles
            or echo "A newly generated profile was preserved for manual inspection." >&2
            pinshift_resign_restore_profiles
            or echo "Provisioning-profile rollback needs manual inspection." >&2
        end
    end

    if set --query _pinshift_resign_staging_root _pinshift_resign_work_root; and not begin
            set --query _pinshift_resign_preserve_staging
            and test "$_pinshift_resign_preserve_staging" = 1
        end
        if test -d "$_pinshift_resign_staging_root"; and test (path dirname "$_pinshift_resign_staging_root") = "$_pinshift_resign_work_root"
            command rm -rf -- "$_pinshift_resign_staging_root"
        end
    end

    if set --query _pinshift_resign_lock_directory
        if test -d "$_pinshift_resign_lock_directory"
            command rmdir "$_pinshift_resign_lock_directory" 2>/dev/null
        end
    end

    if set --query _pinshift_resign_backup_directory
        if test -d "$_pinshift_resign_backup_directory"
            command rmdir "$_pinshift_resign_backup_directory" 2>/dev/null
        end
    end
end

function pinshift_resign_interrupt --on-signal INT
    exit 130
end

function pinshift_resign_terminate --on-signal TERM
    exit 143
end

function pinshift_launch_pinshift_app --argument-names device bundle_identifier output_root
    set --local launch_json "$output_root/launch.json"
    set --local launch_log "$output_root/launch.log"

    xcrun devicectl device process launch \
        --quiet \
        --timeout 60 \
        --terminate-existing \
        --device "$device" \
        --json-output "$launch_json" \
        "$bundle_identifier" >"$launch_log" 2>&1
    set --local launch_status $status

    if test $launch_status -eq 0; and test -f "$launch_json"; and jq --exit-status '.info.outcome == "success"' "$launch_json" >/dev/null 2>&1
        echo "Launch verified on the paired iPhone."
        return 0
    end

    set --local launch_output
    if test -f "$launch_log"
        set launch_output (string collect <"$launch_log")
    end
    if string match --quiet --regex 'Locked|could not be unlocked' -- "$launch_output"
        echo "Pinshift is installed. Unlock the iPhone and open it to finish launch verification." >&2
        return 0
    end

    echo "Pinshift is installed, but automatic launch verification failed." >&2
    echo "Unlock the iPhone and run pinshift-resign-app --launch-only, or open Pinshift manually." >&2
    return 1
end

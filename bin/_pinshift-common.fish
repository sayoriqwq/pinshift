function pinshift_prepare_environment
    set --local repo_root (path resolve (path dirname (status filename))/..)
    cd $repo_root
    or return 1

    if not set --query PINSHIFT_DEVELOPER_DIR
        set --global --export PINSHIFT_DEVELOPER_DIR /Applications/Xcode-beta.app/Contents/Developer
    end
    set --global --export DEVELOPER_DIR $PINSHIFT_DEVELOPER_DIR

    if not test -d $DEVELOPER_DIR
        echo "Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
        echo "Install Xcode Beta or override PINSHIFT_DEVELOPER_DIR in .env.local." >&2
        return 1
    end

    if set --query PINSHIFT_DEVICE; and test -n "$PINSHIFT_DEVICE"
        return 0
    end

    if not command --query jq
        echo "jq is unavailable. Enter the repository through direnv, then retry." >&2
        return 1
    end

    set --local device_json (mktemp -t pinshift-devices.XXXXXX)
    or return 1

    xcrun devicectl list devices --quiet --json-output $device_json >/dev/null 2>&1
    set --local devicectl_status $status
    if test $devicectl_status -ne 0
        command rm -f -- $device_json
        echo "Unable to inspect paired devices. Connect and unlock the iPhone, then retry." >&2
        return $devicectl_status
    end

    set --local device_ids (jq --raw-output '
        .result.devices
        | map(select(
            .properties.hardware.reality == "physical"
            and .properties.hardware.platform == "iOS"
            and .properties.connection.pairingState == "paired"
        ))
        | .[].identifier
    ' $device_json)
    command rm -f -- $device_json

    if test (count $device_ids) -eq 1
        set --global --export PINSHIFT_DEVICE $device_ids[1]
        echo "Using the only paired physical iPhone." >&2
        return 0
    end

    if test (count $device_ids) -eq 0
        echo "No paired physical iPhone was found. Connect and unlock it, then retry." >&2
    else
        echo "Multiple paired physical iPhones were found." >&2
    end
    echo "Copy .env.example to .env.local and set PINSHIFT_DEVICE privately." >&2
    return 1
end

function pinshift_controller_source_fingerprint
    set --local files Package.swift
    if test -f Package.resolved
        set --append files Package.resolved
    end
    set --append files (find Sources -type f -name '*.swift' | sort)

    begin
        for file in $files
            git hash-object $file
            or return 1
        end
    end | shasum -a 256 | string split ' ' --fields 1
end

function pinshift_controller_executable
    set --local install_root (path resolve .build/controller)
    set --local executable $install_root/bin/pinshift-controller
    set --local requirement_file $install_root/designated-requirement
    set --local source_file $install_root/source-fingerprint

    if not test -x $executable; or not test -f $requirement_file; or not test -f $source_file
        echo "The stable controller is not installed. Run pinshift-install once." >&2
        return 1
    end
    codesign --verify --strict $executable >/dev/null 2>&1
    or begin
        echo "The installed controller signature is invalid. Run pinshift-install." >&2
        return 1
    end

    set --local actual_requirement (codesign -d -r- $executable 2>&1 | string match -r '^designated => .*')
    set --local expected_requirement (string collect < $requirement_file)
    set --local required_identifier dev.sayori.pinshift.controller
    if test -z "$actual_requirement"; or not string match --quiet "*identifier \"$required_identifier\"*" $actual_requirement
        echo "The installed controller does not have the required fixed identifier. Run pinshift-install." >&2
        return 1
    end
    if test "$actual_requirement" != "$expected_requirement"
        echo "The installed controller signing identity changed. Refusing to use it; inspect before reinstalling." >&2
        return 1
    end
    if string match --quiet '*cdhash H*' $actual_requirement
        echo "The installed controller has an unstable ad-hoc signature. Run pinshift-install." >&2
        return 1
    end

    set --local installed_source (string trim < $source_file)
    set --local current_source (pinshift_controller_source_fingerprint)
    or return 1
    if test "$installed_source" != "$current_source"
        echo "The controller source changed after installation. Run pinshift-install to update it." >&2
        return 1
    end

    echo $executable
end

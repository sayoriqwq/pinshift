#!/usr/bin/env fish
# Local fixed worker, explicitly owned by the visible Terminal session.
set --local script_dir (path resolve (path dirname (status filename)))
source $script_dir/_pinshift-common.fish
or exit 1
pinshift_prepare_environment
or exit 1
set --local result_directory (path resolve .build/pinshift-remote)
set --global _pinshift_remote_lock "$result_directory/preparing"
function remote_cleanup --on-event fish_exit
    command rmdir "$_pinshift_remote_lock" 2>/dev/null
end
umask 077
echo 'Preparing Pinshift. Keep this terminal open while using the controller.'
$script_dir/pinshift-resign-app --no-launch 2>&1 | tee "$result_directory/preparation.log"
set --local app_status $pipestatus[1]
printf '%s\n' "$app_status" > "$result_directory/app-status.next"
and mv "$result_directory/app-status.next" "$result_directory/app-status"
or exit 1
if contains -- "$app_status" 130 143
    exit $app_status
end
if test $app_status -ne 0
    echo 'App preparation failed/unconfirmed. Existing usable apps can still connect; follow the instructions above.' >&2
end
set --local controller (pinshift_controller_executable)
or exit 1
set --local session_state ($controller link session-state)
or exit 1
for attempt in (seq 1 30)
    if test "$session_state" != stopping
        break
    end
    sleep 1
    set session_state ($controller link session-state)
    or exit 1
end
if test "$session_state" = stopping
    echo 'manual: the existing controller is still clearing before exit. Wait for that terminal to finish, then retry.' >&2
    exit 1
end
if contains -- "$session_state" starting ready
    echo "Reusing the existing controller session ($session_state); no Clear or second controller was requested."
    exit $app_status
end
# Signing has finished. The controller's advisory lock arbitrates simultaneous local startup.
command rmdir "$_pinshift_remote_lock"
or exit 1
set --erase _pinshift_remote_lock
set --global --export PINSHIFT_REPOSITORY_ROOT (path resolve "$script_dir/..")
exec $controller link serve --device "$PINSHIFT_DEVICE" --developer-directory "$PINSHIFT_DEVELOPER_DIR"

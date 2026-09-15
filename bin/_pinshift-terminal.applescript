on run argv
    with timeout of 30 seconds
        tell application "Terminal"
            activate
            do script "/bin/sh " & quoted form of (item 1 of argv)
        end tell
    end timeout
end run

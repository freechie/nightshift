-- Drive the Nightshift Swift status item. Printed lines are the contract
-- scripts/verify-nightshift parses. The status item's title is the warmth
-- percent, so the stable handle is the description "Nightshift".
on run argv
	if (count of argv) < 1 then error "usage: verify-nightshift-ui <command> [pane]"
	set cmd to item 1 of argv
	if cmd is "window" then
		return windowLine()
	else if cmd is "toolbar" then
		return toolbarLine()
	else if cmd is "page" then
		return pageLine()
	else if cmd is "bounds" then
		return boundsLine()
	else if cmd is "dump" then
		return dumpLine()
	else if cmd is "open-settings" then
		openSettings()
		return "OPENED"
	else if cmd is "select" then
		if (count of argv) < 2 then error "select needs a pane name"
		selectPane(item 2 of argv)
		return "SELECTED " & item 2 of argv
	else if cmd is "close-window" then
		closeWindow()
		return "CLOSED"
	else
		error "unknown command " & cmd
	end if
end run

on requireProcess()
	tell application "System Events"
		if not (exists process "nightshift-swift") then error "nightshift-swift is not running"
	end tell
end requireProcess

on windowLine()
	requireProcess()
	tell application "System Events"
		tell process "nightshift-swift"
			if (count of windows) is 0 then return "WINDOW none"
			return "WINDOW " & name of window 1
		end tell
	end tell
end windowLine

on toolbarLine()
	requireProcess()
	tell application "System Events"
		tell process "nightshift-swift"
			if (count of windows) is 0 then error "Settings window is not open"
			set collected to {}
			set buttonList to buttons of toolbar 1 of window 1
			repeat with oneButton in buttonList
				set end of collected to name of oneButton
			end repeat
			set AppleScript's text item delimiters to " | "
			set bar to "TOOLBAR " & collected
			set AppleScript's text item delimiters to ""
			return bar
		end tell
	end tell
end toolbarLine

on pageLine()
	set body to dumpLine()
	if body contains "Open at login" then return "PAGE settings"
	if body contains "Install ID" then return "PAGE license"
	if body contains "Automatically Check For Updates" then return "PAGE about"
	return "PAGE unknown"
end pageLine

on boundsLine()
	requireProcess()
	tell application "System Events"
		tell process "nightshift-swift"
			if (count of windows) is 0 then error "Settings window is not open"
			set origin to position of window 1
			set extent to size of window 1
			return "BOUNDS " & (item 1 of origin) & " " & (item 2 of origin) & " " & (item 1 of extent) & " " & (item 2 of extent)
		end tell
	end tell
end boundsLine

on dumpLine()
	requireProcess()
	tell application "System Events"
		tell process "nightshift-swift"
			if (count of windows) is 0 then error "Settings window is not open"
			set bits to value of static texts of window 1
			try
				set bits to bits & (value of static texts of scroll area 1 of window 1)
			end try
			set AppleScript's text item delimiters to linefeed
			set body to bits as string
			set AppleScript's text item delimiters to ""
			return body
		end tell
	end tell
end dumpLine

on statusExtra()
	tell application "System Events"
		tell process "nightshift-swift"
			set barCount to count of menu bars
			repeat with i from barCount to 1 by -1
				set itemCount to count of menu bar items of menu bar i
				repeat with j from 1 to itemCount
					try
						if description of menu bar item j of menu bar i is "Nightshift" then
							return menu bar item j of menu bar i
						end if
					end try
				end repeat
			end repeat
		end tell
	end tell
	error "Nightshift status item not found"
end statusExtra

on openSettings()
	requireProcess()
	set extra to statusExtra()
	tell application "System Events"
		click extra
		delay 0.4
		click menu item "Settings…" of menu 1 of extra
	end tell
end openSettings

on selectPane(paneName)
	requireProcess()
	tell application "System Events"
		tell process "nightshift-swift"
			if (count of windows) is 0 then error "Settings window is not open"
			set frontmost to true
			click button paneName of toolbar 1 of window 1
		end tell
	end tell
end selectPane

on closeWindow()
	requireProcess()
	tell application "System Events"
		tell process "nightshift-swift"
			set frontmost to true
			if (count of windows) is 0 then return
			keystroke "w" using command down
		end tell
	end tell
end closeWindow

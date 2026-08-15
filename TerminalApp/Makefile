test: 
	xcodebuild -project MacTerminal.xcodeproj -scheme MacTerminal       -configuration Release -derivedDataPath /tmp/mt-rel build

open:
	SWIFTTERM_PROFILE_STATS=1 open /tmp/mt-rel/Build/Products/Release/MacTerminal.app

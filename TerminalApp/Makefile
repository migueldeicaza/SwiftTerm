test: 
	xcodebuild -project MacTerminal.xcodeproj -scheme MacTerminal       -configuration Release -derivedDataPath /tmp/mt-con build

open:
	SWIFTTERM_PROFILE_STATS=1 open /tmp/mt-con/Build/Products/Release/MacTerminal.app

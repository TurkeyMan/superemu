solution "DEmu"
	configurations { "Debug", "Release", "UnitTest" }
	platforms { "x86", "x64" }

	-- include the fuji project...
--	fujiDll = true
--	dofile  "../Fuji/Fuji/Private/Project/fujiproj.lua"

	-- include the Haku project...
--	dofile "../Fuji/Haku/Project/hakuproj.lua"

	project "DEmu"
		kind "WindowedApp"
		language "C++"
		files { "**.d", "**.md" }

		objdir "obj/"
		targetdir "bin/"
--		debugdir "../"

		buildoptions { "-transition=intpromote" }

		configuration "Debug"
			optimize "Off"
			symbols "On"

		configuration "Release"
			optimize "Speed"
			symbols "On"

		configuration "UnitTest"
			optimize "Speed"
			flags { "UnitTest" }

		configuration { "platforms:x86" }
			libdirs { "lib/x86/" }
		configuration { "platforms:x64" }
			libdirs { "lib/x64/" }

		configuration {}

--		dofile "../../Fuji/Fuji/Public/Project/fujiconfig.lua"
--		dofile "../../Fuji/Haku/Project/hakuconfig.lua"

--		links { "c", "m", "stdc++", "pthread", "GL", "GLU", "Xxf86vm", "X11", "ogg", "vorbis", "vorbisfile", "asound", "portaudio" }
--		links { "z", "png", "mad" }
		links { "sqlite3" }
		links { "Fuji" }



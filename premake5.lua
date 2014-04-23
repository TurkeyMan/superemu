require "monodevelop"
require "d"

solution "DEmu"
	configurations { "Debug", "Release", "UnitTest" }
	platforms { "x32", "x64" }

	-- include the fuji project...
--	fujiDll = true
--	dofile  "../Fuji/Fuji/Private/Project/fujiproj.lua"

	-- include the Haku project...
--	dofile "../Fuji/Haku/Project/hakuproj.lua"

	project "DEmu"
		kind "WindowedApp"
		language "D"
		files { "**.d", "**.md" }

		objdir "obj/"
		targetdir "bin/"
--		debugdir "../"

		configuration "Debug"
			optimize "Off"
			flags { "Symbols" }

		configuration "Release"
			optimize "Speed"

		configuration "UnitTest"
			optimize "Speed"
			flags { "UnitTest" }

		configuration {}

--		dofile "../../Fuji/Fuji/Public/Project/fujiconfig.lua"
--		dofile "../../Fuji/Haku/Project/hakuconfig.lua"

--		links { "c", "m", "stdc++", "pthread", "GL", "GLU", "Xxf86vm", "X11", "ogg", "vorbis", "vorbisfile", "asound", "portaudio" }
--		links { "z", "png", "mad" }
		links { "sqlite3" }
		links { "Fuji" }



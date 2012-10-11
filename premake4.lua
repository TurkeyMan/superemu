solution "SuperEmu"
	configurations { "Debug", "Release", "UnitTest" }
--	platforms { "Native", "x32", "x64" }
	platforms { "Native" }

	-- include the fuji project...
--	fujiDll = true
--	dofile  "../Fuji/Fuji/Private/Project/fujiproj.lua"

	-- include the Haku project...
--	dofile "../Fuji/Haku/Project/hakuproj.lua"

	project "SuperEmu"
		kind "WindowedApp"
		language "D"
		files { "src/**.d" }

		objdir "obj/"
		targetdir "bin/"
--		debugdir "../"

		configuration "Debug"
			flags { "Symbols" }

		configuration "Release"
			flags { "OptimizeSpeed" }

		configuration "UnitTest"
			flags { "UnitTest", "OptimizeSpeed" }

		configuration {}

--		dofile "../../Fuji/Fuji/Public/Project/fujiconfig.lua"
--		dofile "../../Fuji/Haku/Project/hakuconfig.lua"

--		links { "c", "m", "stdc++", "pthread", "GL", "GLU", "Xxf86vm", "X11", "ogg", "vorbis", "vorbisfile", "asound", "portaudio" }
--		links { "z", "png", "mad" }
		links { "sqlite3" }
		links { "Fuji" }



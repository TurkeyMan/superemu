module demu.rommanager.romscanner;

import demu.rommanager.romdatabase;
import demu.rommanager.game;

import std.file;
import std.string;
import std.path;

string[] romPaths =
[
	"roms"
];

RomInstance[] ScanRoms(RomDatabase db, RomInstance[] cache)
{
	RomInstance[] roms;

	void AddRom(string path, uint size, std.datetime.time_t modified)
	{
		// should we consider rejecting the file?
		//...
		// text files and stuff, how can we determine this?

		string system = GuessSystem(path);
		const(SystemDesc)* pDesc = system ? db.FindSystem(system) : null;

		roms ~= RomInstance( 0, path, size, 0, modified, system, null, pDesc);
	}

	foreach(path; romPaths)
	{
		foreach(DirEntry e; dirEntries(path, SpanMode.depth))
		{
			if(e.isFile)
			{
				// check it the file is an archive
				if(IsArchive(e.name) != Archive.Unknown)
				{
					// scan archive?
//					AddRom(arc.rom.name, arc.rom.size, e.timeLastModified());

					assert(false, "Archive format not supported!");
				}
				else
				{
					AddRom(e.name, cast(uint)e.size, e.timeLastModified().toUnixTime());
				}
			}
		}
	}
	return roms;
}

private:

enum Archive
{
	Unknown,

	Zip,
	Tar,
	Gunzip,
	SevenZip,
	BZip,
	BZip2,
	Rar,
	Cab
}

Archive IsArchive(string filename)
{
	string ext = getExt(filename);
	if(ext)
	{
		ext = tolower(ext);
		switch(ext)
		{
			case "zip":
				return Archive.Zip;
			case "gz":
			case "gzip":
			case "gunzip":
				return Archive.Gunzip;
			case "tar":
				return Archive.Tar;
			case "7z":
			case "7zip":
				return Archive.SevenZip;
			case "bz":
			case "bzip":
				return Archive.BZip;
			case "bz2":
			case "bzip2":
				return Archive.BZip2;
			case "rar":
				return Archive.Rar;
			case "cab":
				return Archive.Cab;
			default:
		}
	}
	return Archive.Unknown;
}

string GuessSystem(string filename)
{
	string ext = getExt(filename);
	if(ext)
	{
		ext = tolower(ext);

		// run through a big list of known extensions
		switch(ext)
		{
			// atari systems
			case "a26":
				return "a26"; // Atari 2600
			case "a52":
				return "a52"; // Atari 5200
			case "a78":
				return "a78"; // Atari 7800
			case "lnx":
				return "lynx"; // Atari Lynx
			case "jag":
				return "jag"; // Atari Jaguar

			// sega systems
			case "sms":
				return "sms"; // Sega Master System
			case "gg":
				return "gg"; // Sega Game Gear
			case "gen":
			case "smd":
			case "md":
			case "32x":
				return "gen"; // Sega Genesis

			// nintendo systems
			case "nes":
				return "nes"; // Nintendo NES
			case "smc":
			case "sfc":
				return "snes"; // Nintendo SNES
			case "n64":
			case "z64":
			case "u64":
			case "v64":
			case "j64":
				return "n64"; // Nintendo 64
			case "gb":
			case "gbc":
				return "gbx"; // Nintendo Gmeboy/Gameboy Colour
			case "vb":
				return "vb"; // Nintendo Virtual Boy
			case "gba":
				return "gba"; // Nintendo Gameboy Advance

			// misc systems
			case "col":
				return "col"; // Nintendo ColecoVision
			case "int":
				return "intv"; // Nintendo Intellivision
			case "pce":
				return "pce"; // Nintendo PC-Engine
			case "ngp":
			case "ngc":
				return "ngp"; // Nintendo NeoGeo Pocket/Colour

			case "chf":
				return "chaf"; // ??
			case "coco":
				return "coco"; // ??
			default:
				break;
		}
	}

	// find buzzwords in the path

	// find buzzwords in the filename

	// do various machines have binary signatures?

	return null;
}

module demu.rommanager.romdatabase;

import demu.rommanager.romscanner;
import demu.rommanager.game;

import demu.tools.sqlitedb;
import demu.tools.error;

import std.c.stdio;
import std.path;

class RomDatabase
{
	this()
	{
		db = new SQLiteDB("roms.db");

		ErrorCode ec = db.Attach("registry.db", "registry");
		assert(ec == ErrorCode.Success, db.GetErrorMessage());

		systemDescTable = db.FetchTable!SystemDesc("registry", "systems");
		// if this doesn't exist, we need to fetch it from the net...
		if(!systemDescTable) // but for now we'll hard code it.
		{
			systemDescTable = sSystems;
			db.Insert(systemDescTable, "registry", "systems");
		}

		// load roms and update system pointers
		roms = db.FetchTable!RomInstance(null, "roms");
		foreach(ref rom; roms)
		{
			if(rom.system)
				rom.pSystem = FindSystem(rom.system);
		}

		// scan local roms... (we will want to defer this to a separate thread and update in the background)
		RomInstance[] scanRoms = ScanRoms(this, roms);
		UpdateLocalRoms(scanRoms);

		// fetch metadata from: http://api.superfamicom.org/1/game/[int crc, crc32, md5, sha1, sha256]
	}

	void Close()
	{
		db.Close();
		db = null;
	}

	RomInstance* FindRom(uint hash)
	{
		foreach(ref r; roms)
		{
			if(r.hash == hash)
				return &r;
		}
		return null;
	}

	RomInstance* FindRom(string filename)
	{
		foreach(ref r; roms)
		{
			string name = baseName(r.path);
			if(filenameCmp(name, filename) == 0 || filenameCmp(stripExtension(name), filename) == 0)
				return &r;
		}
		return null;
	}

	ubyte[] LoadRom(const(RomInstance)* rom)
	{
		if(!rom)
			return null;
		return cast(ubyte[])std.file.read(rom.path);
	}

	const(SystemDesc)* FindSystem(string sysid)
	{
		foreach(ref sys; systemDescTable)
		{
			if(sys.id[] == sysid[])
				return &sys;
		}
		return null;
	}

private:
	SQLiteDB db;

	RomInstance[] roms;
	const(RomDesc)[] romDescTable;
	const(SystemDesc)[] systemDescTable;

	const(RomDesc)*[uint] romLookup; // index by hash
	const(SystemDesc)*[string] systemLookup; // index by sys id

	void UpdateLocalRoms(RomInstance[] scan)
	{
		if(!roms)
		{
			// just add them all!
			roms = scan;
			db.Insert(roms[], null, "roms");
			return;
		}

		// find which have been added/removed/touched and update accordingly...
		size_t[] added; // index into scan[] of new items
		bool[] exists = new bool[roms.length]; // set for each rom in roms[] that is found
		size_t[] touched; // index into scan[] of items that were touched

		size_t[string] localRomsLookup;
		foreach(i, rom; roms)
			localRomsLookup[rom.path] = i;

		foreach(i, rom; scan)
		{
			size_t *r;
			r = (rom.path in localRomsLookup);
			if(r)
			{
				exists[*r] = true;
				if(roms[*r].timestamp != rom.timestamp)
					touched ~= i;
			}
			else
				added ~= i;
		}

		// update touched roms first while the indices remain in tact
		foreach(i; touched)
		{
			RomInstance* update = &scan[i];
			RomInstance* rom = &roms[localRomsLookup[update.path]];

			uint k = rom.key;
			*rom = *update;
			rom.key = k;

			// update 'rom' to the database where key = 'k'
			db.Update(rom[0..1], null, "roms");
		}

		// remove any that were missing
		RomInstance[] updated;

		uint[] removed; // key's of removed items
		ptrdiff_t lastMissing = -1;
		foreach(i, b; exists)
		{
			if(!b && lastMissing+1 < i)
			{
				// append slice to new list
				updated ~= roms[lastMissing+1..i];
				removed ~= roms[i].key;
				lastMissing = i;
			}
		}

		if(updated)
			roms = updated;

		// clear items from database WHERE key = 'removed[]'
		db.Delete!RomInstance(removed, null, "roms");

		// add the new ones to the end
		if(added)
		{
			// add new roms to list
			size_t firstNew = roms.length;
			foreach(i; added)
				roms ~= scan[i];

			// insert new roms to database
			db.Insert(roms[firstNew .. firstNew + added.length], null, "roms");
		}
	}
}

private:

static immutable SystemDesc[] sSystems =
[
	SystemDesc(0, "sms", "Sega Master System"),
	SystemDesc(0, "gen", "Sega Genesis"),
	SystemDesc(0, "col", "ColecoVision"),
	SystemDesc(0, "msx", "MSX")
];

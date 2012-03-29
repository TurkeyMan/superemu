module demu.rommanager.romdatabase;

import demu.rommanager.romscanner;
import demu.rommanager.game;

import etc.c.sqlite3;
import std.c.stdio;
import std.string;
import std.path;
import std.traits;

class RomDatabase
{
	enum ErrorCode
	{
		Success = 0,
		Failed,
	}

	this()
	{
		int err = sqlite3_open("roms.db".ptr, &db);
		if(err != SQLITE_OK)
		{
			immutable(char)* pError = sqlite3_errmsg(db);
			assert(pError[0..std.c.string.strlen(pError)]);
			return;
		}

		char* pErrorMessage;
		err = sqlite3_exec(db, cast(char*)"ATTACH DATABASE 'registry.db' as registry".toStringz, null, cast(void*)this, &pErrorMessage);

		systemDescTable = FetchTable!SystemDesc("registry", "systems");
		// if this doesn't exist, we need to fetch it from the net...

		roms = FetchTable!RomInstance(null, "roms");

		// scan local roms... (we will want to defer this to a separate thread and update in the background)
		RomInstance[] scanRoms = ScanRoms(this, roms);
		if(roms)
		{
			UpdateLocalRoms(scanRoms);
		}
		else
		{
			roms = scanRoms;
			Insert(roms, null, "roms");
		}

//		Insert(sSystems, "registry", "systems");
	}

	void Close()
	{
		sqlite3_close(db);
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

	ErrorCode CreateTable(RowStruct)(const(char)[] database = null, const(char)[] name = RowStruct.stringof)
	{
		string fields = TableDesc!RowStruct();
		string query = format("CREATE TABLE %s (%s)", TableName!RowStruct(database, name), fields);

		char* pErrorMessage;
		int e = sqlite3_exec(db, cast(char*)query.toStringz, null, cast(void*)this, &pErrorMessage);

		return e == SQLITE_OK ? ErrorCode.Success : ErrorCode.Failed;
	}

	ErrorCode Insert(RowStruct)(RowStruct[] items, const(char)[] database = null, const(char)[] table = RowStruct.stringof)
	{
		bool bCreated = false;

		foreach(ref item; items)
		{
			string query = format("INSERT INTO %s (%s) VALUES (%s)", TableName!RowStruct(database, table), FieldList!(RowStruct, true)(), ValueList!(true)(item));

		try_again:
			char* pErrorMessage;
			int e = sqlite3_exec(db, cast(char*)query.toStringz, null, cast(void*)this, &pErrorMessage);
			if(e == SQLITE_ERROR)
			{
				if(!bCreated)
				{
					// create the table...
					ErrorCode ec = CreateTable!RowStruct(database, table);
					bCreated = true;

					if(ec == ErrorCode.Success)
						goto try_again;
				}

				return ErrorCode.Failed;
			}
		}

		return ErrorCode.Success;
	}

	ErrorCode Update(RowStruct)(RowStruct items[], const(char)[] database = null, const(char)[] table = RowStruct.stringof)
	{
		foreach(ref item; items)
		{
			string query = format("UPDATE %s SET (%s) WHERE %s = '%s'", TableName!RowStruct(database, table), UpdateList!(true)(item), PrimaryKey!RowStruct, PrimaryKeyValue(item));

			char* pErrorMessage;
			int e = sqlite3_exec(db, cast(char*)query.toStringz, null, cast(void*)this, &pErrorMessage);
			if(e == SQLITE_ERROR)
				return ErrorCode.Failed;
		}

		return ErrorCode.Success;
	}

	ErrorCode Delete(RowStruct, K = PrimaryKeyType!RowStruct)(K items[], const(char)[] database = null, const(char)[] table = RowStruct.stringof)
	{
		foreach(ref item; items)
		{
			string query = format("DELETE FROM %s WHERE %s = '%s'", TableName!RowStruct(database, table), PrimaryKey!RowStruct, std.conv.to!string(item));

			char* pErrorMessage;
			int e = sqlite3_exec(db, cast(char*)query.toStringz, null, cast(void*)this, &pErrorMessage);
			if(e == SQLITE_ERROR)
				return ErrorCode.Failed;
		}

		return ErrorCode.Success;
	}

	RowStruct[] FetchTable(RowStruct)(const(char)[] database = null, const(char)[] table = RowStruct.stringof)
	{
		alias int delegate(const(char)*[] values, const(char)*[] columns) QueryResultsDelegate;

		static extern(C) int QueryCallback(void* pUserData, int numColumns, char** ppValues, char** ppColumns)
		{
			return (*cast(QueryResultsDelegate*)pUserData)(ppValues[0..numColumns], ppColumns[0..numColumns]);
		}

		RowStruct[] results;

		int QueryResults(RowStruct)(const(char)*[] values, const(char)*[] columns)
		{
			RowStruct row;
			foreach(i, c; columns)
			{
				const(char)[] col = c[0..core.stdc.string.strlen(c)];

				foreach(immutable string m; __traits(allMembers, RowStruct))
				{
					alias typeof(__traits(getMember, row, m)) Item;
					static if(isPointer!Item)
					{
						// skip the pointers
						continue;
					}
					else
					{
						if(std.algorithm.cmp(m, col) == 0)
						{
							const(char)* v = values[i];
							const(char)[] val = v[0..core.stdc.string.strlen(v)];
							static if(isSomeString!Item)
								__traits(getMember, row, m) = val.idup;
							else
								__traits(getMember, row, m) = std.conv.parse!Item(val);
							break;
						}
					}
				}
			}

			results ~= row;
			return 0;
		}

		QueryResultsDelegate r = &QueryResults!RowStruct;

		string query = "SELECT * FROM " ~ TableName!RowStruct(database, table);

		char* pErrorMessage;
		int e = sqlite3_exec(db, query.toStringz, &QueryCallback, cast(void*)&r, &pErrorMessage);

		if(e == SQLITE_ERROR)
			return null;

		return results;
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
	sqlite3* db;

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
			Insert(roms[], null, "roms");
			return;
		}

		// find which have been added/removed/touched and update accordingly...
		int[] added; // index into scan[] of new items
		bool[] exists = new bool[roms.length]; // set for each rom in roms[] that is found
		int[] touched; // index into scan[] of items that were touched

		int[string] localRomsLookup;
		foreach(i, rom; roms)
			localRomsLookup[rom.path] = i;

		foreach(i, rom; scan)
		{
			int *r;
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

			int k = rom.key;
			*rom = *update;
			rom.key = k;

			// update 'rom' to the database where key = 'k'
			Update(rom[0..1], null, "roms");
		}

		// remove any that were missing
		RomInstance[] updated;

		int[] removed; // key's of removed items
		int lastMissing = -1;
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
		Delete!RomInstance(removed, null, "roms");

		// add the new ones to the end
		if(added)
		{
			// add new roms to list
			int firstNew = roms.length;
			foreach(i; added)
				roms ~= scan[i];

			// insert new roms to database
			Insert(roms[firstNew .. firstNew + added.length], null, "roms");
		}
	}
}

private:

template PrimaryKey(T)
{
	enum string PrimaryKey = __traits(allMembers, T)[0];
}

template PrimaryKeyType(T)
{
	alias typeof(__traits(getMember, T, __traits(allMembers, T)[0])) PrimaryKeyType;
}

string PrimaryKeyValue(T)(ref T row)
{
	return std.conv.to!string(__traits(getMember, row, PrimaryKey!T));
}

string TableName(T = void)(const(char)[] database = null, const(char)[] name = T.stringof)
{
	return format("%s%s", database ? format("%s.", database) : "", name);
}

string TableDesc(T, bool bDesc = false)()
{
	string fields;
	foreach(i, m; __traits(allMembers, T))
	{
		alias typeof(__traits(getMember, T, m)) Item;
		if(isPointer!Item)
		{
		   continue;
		}
		else
		{
			if(i > 0)
				fields ~= ", ";

			fields ~= "'" ~ m ~ "'";

			if(__traits(isIntegral, Item))
				fields ~= " INTEGER";
			else if(__traits(isFloating, Item))
				fields ~= " NUMERIC"; // " REAL"
			else
				fields ~= " TEXT";

			if(m[] == PrimaryKey!T)
				fields ~= " PRIMARY KEY" ~ (bDesc ? " DESC" : " ASC");
		}
	}

	return fields;
}

string FieldList(T, bool SkipPK = false)()
{
	string fields;
	foreach(i, m; __traits(allMembers, T))
	{
		alias typeof(__traits(getMember, T, m)) Item;
		static if((SkipPK && m[] == PrimaryKey!T) || isPointer!Item)
		{
			continue;
		}
		else
		{
			if(fields != null)
				fields ~= ", ";

			fields ~= "'" ~ m ~ "'";
		}
	}
	return fields;
}

string ValueList(bool SkipPK = false, T)(ref const(T) row)
{
	char[] fields;
	foreach(i, immutable string m; __traits(allMembers, T))
	{
		alias typeof(__traits(getMember, T, m)) Item;
		static if((SkipPK && m[] == PrimaryKey!T) || isPointer!Item)
		{
			continue;
		}
		else
		{
			if(fields != null)
				fields ~= ", ";

			string value = std.conv.to!string(__traits(getMember, row, m));
			fields ~= "'" ~ value ~ "'";
		}
	}

	return fields.idup;
}

string UpdateList(bool SkipPK = false, T)(ref const(T) row)
{
	char[] fields;
	foreach(i, immutable string m; __traits(allMembers, T))
	{
		alias typeof(__traits(getMember, T, m)) Item;
		static if((SkipPK && m[] == PrimaryKey!T) || isPointer!Item)
		{
			continue;
		}
		else
		{
			if(fields != null)
				fields ~= ", ";

			string value = std.conv.to!string(__traits(getMember, row, m));
			fields ~= "'" ~ m ~ "' = '" ~ value ~ "'";
		}
	}

	return fields.idup;
}

static immutable SystemDesc[] sSystems =
[
	SystemDesc(0, "sms", "Sega Master System"),
	SystemDesc(0, "gen", "Sega Genesis"),
	SystemDesc(0, "col", "ColecoVision"),
	SystemDesc(0, "msx", "MSX")
];

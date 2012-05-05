module demu.tools.sqlitedb;

import demu.tools.error;

import etc.c.sqlite3;

import std.traits;
import std.string;

const(char)[] dString(in char* cString)
{
	return cString[0..core.stdc.string.strlen(cString)];
}

class SQLiteDB
{
	this()
	{
	}

	this(const(char)[] filename)
	{
		ErrorCode ec = Open(filename);
		assert(ec == ErrorCode.Success, "Couldn't open database");
	}

	~this()
	{
		Close();
	}

	ErrorCode Open(const(char)[] filename)
	{
		int err = sqlite3_open(filename.toStringz, &db);
		if(err != SQLITE_OK)
		{
			assert(false, GetErrorMessage());
			return ErrorCode.Failed;
		}

		return ErrorCode.Success;
	}

	void Close()
	{
		sqlite3_close(db);
		db = null;
	}

	ErrorCode Attach(const(char)[] filename, const(char)[] name)
	{
		assert(db != null, "No database loaded");

		string query = format("ATTACH DATABASE '%s' as %s", filename, name);

		char* pErrorMessage;
		int e = sqlite3_exec(db, query.toStringz, null, null, &pErrorMessage);
		if(e != SQLITE_OK)
			return ErrorCode.Failed;
		return ErrorCode.Success;
	}

	ErrorCode CreateTable(RowStruct)(const(char)[] database = null, const(char)[] name = RowStruct.stringof)
	{
		assert(db != null, "No database loaded");

		string query = format("CREATE TABLE %s (%s)", TableName!RowStruct(database, name), TableDesc!RowStruct());

		char* pErrorMessage;
		int e = sqlite3_exec(db, cast(char*)query.toStringz, null, cast(void*)this, &pErrorMessage);

		return e == SQLITE_OK ? ErrorCode.Success : ErrorCode.Failed;
	}

	ErrorCode Insert(RowStruct)(RowStruct[] items, const(char)[] database = null, const(char)[] table = RowStruct.stringof)
	{
		assert(db != null, "No database loaded");

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
		assert(db != null, "No database loaded");

		foreach(ref item; items)
		{
			string query = format("UPDATE %s SET (%s) WHERE %s = '%s'", TableName!RowStruct(database, table), UpdateList!(true)(item), PrimaryKeyField!RowStruct, PrimaryKeyValue(item));

			char* pErrorMessage;
			int e = sqlite3_exec(db, cast(char*)query.toStringz, null, cast(void*)this, &pErrorMessage);
			if(e == SQLITE_ERROR)
				return ErrorCode.Failed;
		}

		return ErrorCode.Success;
	}

	ErrorCode Delete(RowStruct, K = PrimaryKeyType!RowStruct)(K items[], const(char)[] database = null, const(char)[] table = RowStruct.stringof)
	{
		assert(db != null, "No database loaded");

		foreach(ref item; items)
		{
			string query = format("DELETE FROM %s WHERE %s = '%s'", TableName!RowStruct(database, table), PrimaryKeyField!RowStruct, std.conv.to!string(item));

			char* pErrorMessage;
			int e = sqlite3_exec(db, cast(char*)query.toStringz, null, cast(void*)this, &pErrorMessage);
			if(e == SQLITE_ERROR)
				return ErrorCode.Failed;
		}

		return ErrorCode.Success;
	}

	RowStruct[] FetchTable(RowStruct)(const(char)[] database = null, const(char)[] table = RowStruct.stringof)
	{
		assert(db != null, "No database loaded");

		alias int delegate(in char*[] values, in char*[] columns) QueryResultsDelegate;

		static extern(C) int QueryCallback(void* pUserData, int numColumns, char** ppValues, char** ppColumns)
		{
			return (*cast(QueryResultsDelegate*)pUserData)(ppValues[0..numColumns], ppColumns[0..numColumns]);
		}

		RowStruct[] results;

		int QueryResults(RowStruct)(in char*[] values, in char*[] columns)
		{
			RowStruct row;
			foreach(i, c; columns)
			{
				const(char)[] col = dString(c);

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
							const(char)[] val = dString(v);
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

	const(char)[] GetErrorMessage()
	{
		return dString(sqlite3_errmsg(db));
	}

private:
	sqlite3* db;
}


private:

template PrimaryKeyField(T)
{
	// is there a cool way we can tag the PK without attributes?
	enum string PrimaryKeyField = __traits(allMembers, T)[0];
}

template PrimaryKeyType(T)
{
	alias typeof(__traits(getMember, T, PrimaryKeyField!T)) PrimaryKeyType;
}

string PrimaryKeyValue(T)(ref T row)
{
	return std.conv.to!string(__traits(getMember, row, PrimaryKeyField!T));
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

			if(m[] == PrimaryKeyField!T)
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
		static if((SkipPK && m[] == PrimaryKeyField!T) || isPointer!Item)
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
		static if((SkipPK && m[] == PrimaryKeyField!T) || isPointer!Item)
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
		static if((SkipPK && m[] == PrimaryKeyField!T) || isPointer!Item)
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

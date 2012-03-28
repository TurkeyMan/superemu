module demu.rommanager.game;

import std.datetime;
import std.file;

enum Region
{
	America,
	Europe,
	Asia,
	China,
	World
}

enum Language
{
	English,
	French,
	Italian,
	German,
	Spanish,
	Portuguese,
	Russian,
	Japanese,
	Chinese,
	Korean
}

enum RomFlags
{
	Verified,
	Pending,

	Alternate,
	Hacked,
	Pirate,
	Trainer,

	Overdump,
	BadDump,
	Fixed
}

struct RomInstance
{
	uint key;

	string path;
	uint size;
	std.datetime.time_t timestamp;
	uint hash;

	const(RomDesc)* pDesc;
	const(SystemDesc)* pSystem;
}

struct RomDesc
{
	uint key;

	uint hash;
	string name;
	string system;

	string fullName;
	string niceName;
	string region;
	string language;
	string flags;
	ushort ver, rev;

	ubyte displayRate;
	ubyte minPlayers, maxPlayers;

	string bootParams;
}

struct SystemDesc
{
	int key;

	string id;
	string name;
}

module demu.systemregistry;

import demu.rommanager.romdatabase;
import demu.rommanager.game;

import demu.machine;
import demu.systems.segamastersystem;
import demu.systems.segagenesis;
import demu.systems.colecovision;
import demu.systems.msx;

Machine CreateSystem(const(RomInstance)* rom, RomDatabase db, const(char)[] systemID = null)
{
	if(systemID == null)
	{
		assert(rom.system != null, "Unknown system for rom " ~ rom.path ~ "!");
		systemID = rom.system;
	}

	foreach(ref sys; sSystems)
	{
		if(systemID[] == sys.id[])
			return sys.create(rom, db);
	}
	assert(false, "Unknown system " ~ systemID ~ "!");
	return null;
}

private:

alias Machine function(const(RomInstance)* rom, RomDatabase db) CreateFunc;

struct System
{
	string id;
	CreateFunc create;
	SystemDesc* desc;
}

shared immutable(System[]) sSystems =
[
	System( "sms", &CreateMachine!SegaMasterSystem ),
	System( "gen", &CreateMachine!SegaGenesis ),
	System( "col", &CreateMachine!ColecoVision ),
	System( "msx", &CreateMachine!MSX )
];

Machine CreateMachine(T)(const(RomInstance)* rom, RomDatabase db)
{
	return new T(rom, db);
}

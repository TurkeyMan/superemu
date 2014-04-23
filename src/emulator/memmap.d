module demu.emulator.memmap;

import std.string;
import demu.emulator.machine;

alias ubyte delegate(uint address)				Read8Handler;
alias void delegate(uint address, ubyte value)	Write8Handler;
alias ushort delegate(uint address)				Read16Handler;
alias void delegate(uint address, ushort value)	Write16Handler;
alias uint delegate(uint address)				Read32Handler;
alias void delegate(uint address, uint value)	Write32Handler;

enum MemFlags
{
	Read = 0x01,
	Write = 0x02,
	Opcode = 0x04,
	Disassembled = 0x08,

	NoDebug = 0x10,  // the debugger will not display the contents of this memory
	Banked = 0x20,   // this range uses bank switching

	// compound flags
	ReadOnly = Read,
	WriteOnly = Write,
	ReadWrite = Read | Write,
}

struct MemoryCallbacks
{
	Read8Handler read8;
	Write8Handler write8;
	Read16Handler read16;
	Write16Handler write16;
	Read32Handler read32;
	Write32Handler write32;
}

final class MemoryRange
{
	this(string name, uint start, uint end, uint mask, uint flags, int byteWidth = 8, int numBanks = 1)
	{
		this.name = name;
		this.start = start;
		this.end = end;
		this.mask = mask;
		this.byteWidth = byteWidth;
		this.numBanks = numBanks;

		// init mem-tracking data
	}

	// mem range info
	@property uint Start() { return start; }
	@property uint Length() { return end - start; }

	// members
	string name;
	uint start, end, mask;    // the range to map
	uint flags;               // memory access flags
	int byteWidth;            // width of a single addressable unit of memory, in bits

	int bank;                 // current bank
	int numBanks;             // number of banks the range can address

	// auto-range support
	ubyte romImage[];
	bool bManaged;
}

final class MemMap
{
	this(Machine machine, uint addressBits, bool bTrapUndefinedAccess = false)
	{
		this.machine = machine;
		this.addressBits = addressBits;
		this.bTrapUndefinedAccess = bTrapUndefinedAccess;

		int entries = 1 << (addressBits - 8);
		memory = new Block[entries];

		foreach(ref e; memory)
			e.flags = BlockFlags.Callback | BlockFlags.InvalidAccess;

		ioRead = &UnMappedIORead;
		ioWrite = &UnMappedIOWrite;

		// debug stuff?
	}

	void RegisterMemoryCallbacks(MemoryCallbacks callbacks[])
	{
		this.callbacks = callbacks;
	}

	void RegisterIOCallbacks(Read8Handler ioRead, Write8Handler ioWrite)
	{
		this.ioRead = ioRead;
		this.ioWrite = ioWrite;
	}

	void RegisterIllegalAddressCallbacks(Read32Handler illegalRead, Write32Handler illegalWrite)
	{
		this.illegalRead = illegalRead;
		this.illegalWrite = illegalWrite;
	}

	// manual configuration functions
	void RegisterMemRangeDirect(MemoryRange description, ubyte* pMemory, uint addressMask = 0xFFFFFFFF)
	{
		assert((description.start & 0xFF) == 0, "Memory range must be 256 byte aligned!");
		assert((cast(size_t)pMemory & 0xF) == 0, "Memory must be aligned to 16 bytes!");
		assert(!GetMemoryRange(description.start, description.end), "Memory range is already mapped");
		assert((description.start < (1U << addressBits)) && (description.end <= (1U << addressBits)), "Memory range larger than address space (will crash)");

		uint flags = description.flags == MemFlags.ReadOnly ? BlockFlags.ReadOnly : 0;

		uint romOffset = 0;
		for(uint offset = (description.start & 0xFFFFFF00); offset < description.end; offset += 0x100)
		{
			if((offset & description.mask) == offset)
			{
				int entry = offset >> 8;
				assert(entry < (1 << (addressBits - 8)), "Trying to write on an unexisting memory block entry!");

				memory[entry].pPointer = &pMemory[romOffset & addressMask] + flags;

				static if(EnableMemTracking)
					memory[entry].range = description;
			}
			romOffset += 0x100;
		}

		ranges ~= description;
	}

	void RegisterMemRangeCallback(MemoryRange description, int callbackID)
	{
		assert((description.start & 0xFF) == 0, "Memory range must be 256 byte aligned!");
		assert(callbackID < callbacks.length, "Undefined memory callback");
		assert(description.end == alignTo!256(description.end), "Unaligned memory range, will be extended");
		assert(!GetMemoryRange(description.start, description.end), "Memory range is already mapped");
		assert((description.start < (1U << addressBits)) && (description.end <= (1U << addressBits)), "Memory range larger than address space (will crash)");

		uint flags = description.flags == MemFlags.ReadOnly ? BlockFlags.ReadOnly : 0;

		for(uint offset = description.start; offset < description.end; offset += 0x100)
		{
			if((offset & description.mask) == offset)
			{
				int entry = offset >> 8;
				assert(entry < (1 << (addressBits - 8)), "Trying to write on an unexisting memory block entry!");

				memory[entry].flags = BlockFlags.Callback | (callbackID << BlockFlags.CallbackIndex) | flags;

				static if(EnableMemTracking)
					memory[entry].range = description;
			}
		}

		ranges ~= description;
	}

	// simple configuration functions
	ubyte[] MountRomImageDirect(string filename, uint startAddress, uint flags = MemFlags.ReadOnly)
	{
		ubyte[] rom = cast(ubyte[])std.file.read("roms/col/bios/ColecoVision.rom");

		if(rom)
		{
			MemoryRange range = new MemoryRange(filename, startAddress, startAddress + cast(uint)rom.length, (1 << addressBits) - 1, flags, 8);
			range.romImage = rom;

			RegisterMemRangeDirect(range, rom.ptr);
		}

		return rom;
	}

	ubyte[] AllocateMemoryDirect(string name, uint startAddress, uint length, uint flags = MemFlags.ReadWrite)
	{
		ubyte[] mem = new ubyte[length];
		MemoryRange range = new MemoryRange(name, startAddress, startAddress + length, (1 << addressBits) - 1, flags, 8);
		range.romImage = mem;

		RegisterMemRangeDirect(range, mem.ptr);
		return mem;
	}

	void MountRangeDirect(string name, ubyte* pMemory, uint startAddress, uint length, uint flags = MemFlags.ReadWrite, uint mask = 0xFFFFFFFF)
	{
		MemoryRange range = new MemoryRange(name, startAddress, startAddress + length, (1 << addressBits) - 1, flags, 8);

		mask &= ((1 << addressBits) - 1);
		RegisterMemRangeDirect(range, pMemory, mask);
	}

	void MountRangeCallback(string name, int callbackID, uint startAddress, uint length, uint flags = MemFlags.ReadWrite)
	{
		MemoryRange range = new MemoryRange(name, startAddress, startAddress + length, (1 << addressBits) - 1, flags, 8);

		RegisterMemRangeCallback(range, callbackID);
	}

	// update direct memory range (deprecated?)
	void UpdateRangeDirect(uint startAddress, uint endAddress, ubyte* pMemory, uint mask = 0xFFFFFFFF)
	{
		assert((startAddress & 0xFF) == 0, "Memory range must be 256 byte aligned!");

		uint romOffset = 0;
		for(uint offset = startAddress; offset < endAddress; offset += 0x100)
		{
			int entry = offset >> 8;
			uint readOnly = this.memory[entry].flags & BlockFlags.ReadOnly;
			if(pMemory)
				this.memory[entry].pPointer = pMemory + (romOffset & mask) + readOnly;
			else
				this.memory[entry].flags = BlockFlags.Callback | BlockFlags.InvalidAccess | readOnly;
			romOffset += 0x100;
		}
	}

	// swap a ranged bank
	void SwapBankDirect(uint startAddress, ubyte memory[], int bankID, uint flags = MemFlags.ReadWrite, uint mask = 0xFFFFFFFF)
	{
	}

	void SwapBankCallback(uint startAddress, int callbackID, int bankID, uint flags = MemFlags.ReadWrite)
	{
	}

	// misc functions
	ubyte* GetPointerDirect(uint address) const
	{
		const Block* block = &memory[address >> 8];

		// we can't get a direct pointer for callback on unmapped addresses
		if(block.flags & BlockFlags.Callback)
			return null;

		// return the pointer to the memory
		ubyte* pPointer = cast(ubyte*)(cast(size_t)block.pPointer & ~0xF);
		return pPointer + (address & 0xFF);
	}

	// memory access interface
	ubyte Read8(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead8(address);
		ubyte* pPointer = cast(ubyte*)(cast(size_t)block.pPointer & ~0xF);
		return pPointer[address & 0xFF];
	}

	void Write8(uint address, ubyte value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite8(address, value);
		else
			block.pPointer[address & 0xFF] = value;
	}

	// 16 bit accessors come in little and big endian varieties
	ushort Read16_LE(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead16_LE(address);
		ubyte* pPointer = cast(ubyte*)(cast(size_t)block.pPointer & ~0xF);
		int offset = address & 0xFF;
		return pPointer[offset] | (pPointer[offset + 1] << 8);
	}

	ushort Read16_BE(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead16_BE(address);
		ubyte* pPointer = cast(ubyte*)(cast(size_t)block.pPointer & ~0xF);
		int offset = address & 0xFF;
		return pPointer[offset + 1] | (pPointer[offset] << 8);
	}

	void Write16_LE(uint address, ushort value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite16_LE(address, value);
		else
		{
			int offset = address & 0xFF;
			block.pPointer[offset] = value & 0xFF;
			block.pPointer[offset + 1] = value >> 8;
		}
	}

	void Write16_BE(uint address, ushort value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite16_BE(address, value);
		else
		{
			int offset = address & 0xFF;
			block.pPointer[offset] = value >> 8;
			block.pPointer[offset + 1] = value & 0xFF;
		}
	}

	// these 16 bit accessors are faster for when we know the data we're loading is aligned
	ushort Read16_Aligned(Endian endian)(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead16_LE(address);
		int offset = address & 0xFF;
		ushort t = *cast(ushort*)((cast(size_t)block.pPointer & ~0xF) + offset);
		static if(endian != SystemEndian)
			t = cast(ushort)((t >> 8) | (t << 8));
		return t;
	}

	void Write16_Aligned(Endian endian)(uint address, ushort value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite16_LE(address, value);
		else
		{
			static if(endian != SystemEndian)
				value = cast(ushort)((value >> 8) | (value << 8));
			int offset = address & 0xFF;
			*cast(ushort*)(block.pPointer + offset) = value;
		}
	}

	// 32 bit accessors come in little and big endian varieties
	uint Read32_LE(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead32_LE(address);
		ubyte* pPointer = cast(ubyte*)(cast(size_t)block.pPointer & ~0xF);
		int offset = address & 0xFF;
		return pPointer[offset] | (pPointer[offset + 1] << 8) | (pPointer[offset + 2] << 16) | (pPointer[offset + 3] << 24);
	}

	uint Read32_BE(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead32_BE(address);
		ubyte* pPointer = cast(ubyte*)(cast(size_t)block.pPointer & ~0xF);
		int offset = address & 0xFF;
		return pPointer[offset + 3] | (pPointer[offset + 2] << 8) | (pPointer[offset + 1] << 16) | (pPointer[offset] << 24);
	}

	void Write32_LE(uint address, uint value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite32_LE(address, value);
		else
		{
			int offset = address & 0xFF;
			block.pPointer[offset] = value & 0xFF;
			block.pPointer[offset + 1] = (value >> 8) & 0xFF;
			block.pPointer[offset + 2] = (value >> 16) & 0xFF;
			block.pPointer[offset + 3] = value >> 24;
		}
	}

	void Write32_BE(uint address, uint value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite32_BE(address, value);
		else
		{
			int offset = address & 0xFF;
			block.pPointer[offset] = value >> 24;
			block.pPointer[offset + 1] = (value >> 16) & 0xFF;
			block.pPointer[offset + 2] = (value >> 8) & 0xFF;
			block.pPointer[offset + 3] = value & 0xFF;
		}
	}

	// 32bit aligned accessors
	uint Read32_Aligned(Endian endian)(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead32_LE(address);
		int offset = address & 0xFF;
		uint t = *cast(uint*)((cast(size_t)block.pPointer & ~0xF) + offset);
		static if(endian != SystemEndian)
			t = (t >> 24) | ((t >> 8) & 0xFF00) | ((t & 0xFF00) << 8) | (t << 24);
		return t;
	}

	void Write32_Aligned(Endian endian)(uint address, uint value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite32_LE(address, value);
		else
		{
			static if(endian != SystemEndian)
				value = (value >> 24) | ((value >> 8) & 0xFF00) | ((value & 0xFF00) << 8) | (value << 24);
			int offset = address & 0xFF;
			*cast(uint*)(block.pPointer + offset) = value;
		}
	}

	// 32bit accessors with 16 bit alignment
	uint Read32_LE_Aligned_16(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead32_16_LE(address);
		ushort* pData = cast(ushort*)((cast(size_t)block.pPointer & ~0xF) + (address & 0xFF));
		ushort ls = pData[0];
		ushort hs = pData[1];
		version(BigEndian)
		{
			ls = cast(ushort)((ls >> 8) | (ls << 8));
			hs = cast(ushort)((hs >> 8) | (hs << 8));
		}
		return ls | (hs << 16);
	}

	uint Read32_BE_Aligned_16(uint address)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.Callback)
			return ServicedRead32_16_BE(address);
		ushort* pData = cast(ushort*)((cast(size_t)block.pPointer & ~0xF) + (address & 0xFF));
		ushort ls = pData[1];
		ushort hs = pData[0];
		version(LittleEndian)
		{
			ls = cast(ushort)((ls >> 8) | (ls << 8));
			hs = cast(ushort)((hs >> 8) | (hs << 8));
		}
		return ls | (hs << 16);
	}

	void Write32_LE_Aligned_16(uint address, uint value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite32_16_LE(address, value);
		else
		{
			version(BigEndian)
				value = ((value & 0xFF00FF00) >> 8) | ((value & 0x00FF00FF) << 8);
			int offset = address & 0xFF;
			*cast(ushort*)(block.pPointer + offset) = value & 0xFFFF;
			*cast(ushort*)(block.pPointer + offset + 2) = value >> 16;
		}
	}

	void Write32_BE_Aligned_16(uint address, uint value)
	{
		Block* block = &memory[address >> 8];
		if(block.flags & BlockFlags.FlagMask)
			ServicedWrite32_16_BE(address, value);
		else
		{
			version(LittleEndian)
				value = ((value & 0xFF00FF00) >> 8) | ((value & 0x00FF00FF) << 8);
			int offset = address & 0xFF;
			*cast(ushort*)(block.pPointer + offset) = value >> 16;
			*cast(ushort*)(block.pPointer + offset + 2) = value & 0xFFFF;
		}
	}

	// IO port accessors
	ubyte IORead(uint address)
	{
		return ioRead(address);
	}

	void IOWrite(uint address, ubyte value)
	{
		ioWrite(address, value);
	}

	// invalid read
	uint InvalidRead(uint address)
	{
		// call user illegal read callback
		if(illegalRead)
			return illegalRead(address);

		// opportunity to trap invalid reads here
		if(bTrapUndefinedAccess)
		{
			char buff[64];

			static if(EnableMemTracking)
			{
				Block* block = &memory[address >> 8];
				format("Illegal Read from 0x%08X in block '%s'!", address, block.range ? block.range.name : "");
			}
			else
			{
				format("Illegal Read");
			}
/+
			debug machine.FlushLog();

			Debugger dbg = machine.Debugger;
			if(dbg && dbg.IsClientConnected)
			{
				machine.DebugBreak(buff, BR_IllegalAddress);
			}
			else
			{
				assert(false, buff);
			}
+/
		}

		return 0xFFFFFFFF;
	}

	void InvalidWrite(uint address, uint value)
	{
		// call user illegal access callback
		if(illegalWrite)
		{
			illegalWrite(address, value);
			return;
		}

		// opportunity to trap invalid writes here
		if(bTrapUndefinedAccess)
		{
			static if(EnableMemTracking)
			{
				Block* block = &memory[address >> 8];
				format("Illegal Write to 0x%08X in block '%s'!", address, block.range ? block.range.name : "");
			}
			else
			{
				format("Illegal Write");
			}
/+
			debug machine.FlushLog();

			Debugger dbg = machine.Debugger;
			if(dbg && dbg.IsClientConnected)
			{
				machine.DebugBreak(buff, BR_IllegalAddress);
			}
			else
			{
				assert(false, buff);
			}
+/
		}
	}

	// alias the memory functions
	alias Read16_Aligned!(Endian.Little) Read16_LE_Aligned;
	alias Read16_Aligned!(Endian.Big) Read16_BE_Aligned;
	alias Write16_Aligned!(Endian.Little) Write16_LE_Aligned;
	alias Write16_Aligned!(Endian.Big) Write16_BE_Aligned;

	alias Read32_Aligned!(Endian.Little) Read32_LE_Aligned;
	alias Read32_Aligned!(Endian.Big) Read32_BE_Aligned;
	alias Write32_Aligned!(Endian.Little) Write32_LE_Aligned;
	alias Write32_Aligned!(Endian.Big) Write32_BE_Aligned;

private:
	enum BlockFlags
	{
		FlagMask = 0xF,

		Callback = 0x1,      // access through memory callbacks
		InvalidAccess = 0x2, // invalid memory access
		ReadOnly = 0x4,      // memory is read only

		CallbackIndex = 4,
	}

	struct Block
	{
		union
		{
			uint flags;
			ubyte* pPointer;
		}
		static if(EnableMemTracking)
			MemoryRange range;
	}

	// serviced reads via callbacks
	ubyte ServicedRead8(uint address)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & BlockFlags.InvalidAccess)
			return cast(ubyte)InvalidRead(address);

		return callbacks[block.flags >> BlockFlags.CallbackIndex].read8(address);
	}

	void ServicedWrite8(uint address, ubyte value)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & (BlockFlags.InvalidAccess | BlockFlags.ReadOnly))
			InvalidWrite(address, value);
		else
			callbacks[block.flags >> BlockFlags.CallbackIndex].write8(address, value);
	}

	ushort ServicedRead16_LE(uint address)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & BlockFlags.InvalidAccess)
			return cast(ushort)InvalidRead(address);

		MemoryCallbacks* cb = &callbacks[block.flags >> BlockFlags.CallbackIndex];

		if(cb.read16)
			return cb.read16(address);

		ubyte l = cb.read8(address);
		ubyte h = cb.read8(address + 1);
		return (cast(ushort)h << 8) | l;
	}

	void ServicedWrite16_LE(uint address, ushort value)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & (BlockFlags.InvalidAccess | BlockFlags.ReadOnly))
			InvalidWrite(address, value);
		else
		{
			MemoryCallbacks* cb = &callbacks[block.flags >> BlockFlags.CallbackIndex];

			if(cb.write16)
			{
				cb.write16(address, value);
			}
			else
			{
				cb.write8(address, cast(ubyte)(value & 0xFF));
				cb.write8(address + 1, cast(ubyte)(value >> 8));
			}
		}
	}

	ushort ServicedRead16_BE(uint address)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & BlockFlags.InvalidAccess)
			return cast(ushort)InvalidRead(address);

		MemoryCallbacks* cb = &callbacks[block.flags >> BlockFlags.CallbackIndex];

		if(cb.read16)
			return cb.read16(address);

		ubyte h = cb.read8(address);
		ubyte l = cb.read8(address + 1);
		return (cast(ushort)h << 8) | l;
	}

	void ServicedWrite16_BE(uint address, ushort value)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & (BlockFlags.InvalidAccess | BlockFlags.ReadOnly))
			InvalidWrite(address, value);
		else
		{
			MemoryCallbacks* cb = &callbacks[block.flags >> BlockFlags.CallbackIndex];

			if(cb.write16)
			{
				cb.write16(address, value);
			}
			else
			{
				cb.write8(address, cast(ubyte)(value >> 8));
				cb.write8(address + 1, cast(ubyte)(value & 0xFF));
			}
		}
	}

	uint ServicedRead32_LE(uint address)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & BlockFlags.InvalidAccess)
			return InvalidRead(address);

		MemoryCallbacks* cb = &callbacks[block.flags >> BlockFlags.CallbackIndex];

		if(cb.read32)
			return cb.read32(address);

		if(cb.read16)
		{
			ushort l = cb.read16(address);
			ushort h = cb.read16(address + 2);
			return (cast(uint)h << 16) | l;
		}

		ubyte ll = cb.read8(address);
		ubyte hl = cb.read8(address + 1);
		ubyte lh = cb.read8(address + 2);
		ubyte hh = cb.read8(address + 3);
		return (cast(uint)hh << 24) | (cast(uint)lh << 16) | (cast(uint)hl << 8) | ll;
	}

	void ServicedWrite32_LE(uint address, uint value)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & (BlockFlags.InvalidAccess | BlockFlags.ReadOnly))
			InvalidWrite(address, value);
		else
		{
			MemoryCallbacks* cb = &callbacks[block.flags >> BlockFlags.CallbackIndex];

			if(cb.write32)
			{
				cb.write32(address, value);
			}
			else if(cb.write16)
			{
				cb.write16(address, cast(ushort)value);
				cb.write16(address + 2, cast(ushort)(value >> 16));
			}
			else
			{
				cb.write8(address, cast(ubyte)value);
				cb.write8(address + 1, cast(ubyte)(value >> 8));
				cb.write8(address + 2, cast(ubyte)(value >> 16));
				cb.write8(address + 3, cast(ubyte)(value >> 24));
			}
		}
	}

	uint ServicedRead32_BE(uint address)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & BlockFlags.InvalidAccess)
			return InvalidRead(address);

		MemoryCallbacks* cb = &callbacks[block.flags >> BlockFlags.CallbackIndex];

		if(cb.read32)
			return cb.read32(address);

		if(cb.read16)
		{
			ushort h = cb.read16(address);
			ushort l = cb.read16(address + 2);
			return (cast(uint)h << 16) | l;
		}

		ubyte hh = cb.read8(address);
		ubyte lh = cb.read8(address + 1);
		ubyte hl = cb.read8(address + 2);
		ubyte ll = cb.read8(address + 3);
		return (cast(uint)hh << 24) | (cast(uint)lh << 16) | (cast(uint)hl << 8) | ll;
	}

	void ServicedWrite32_BE(uint address, uint value)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & (BlockFlags.InvalidAccess | BlockFlags.ReadOnly))
			InvalidWrite(address, value);
		else
		{
			MemoryCallbacks* cb = &callbacks[block.flags >> BlockFlags.CallbackIndex];

			if(cb.write32)
			{
				cb.write32(address, value);
			}
			else if(cb.write16)
			{
				cb.write16(address, cast(ushort)(value >> 16));
				cb.write16(address + 2, cast(ushort)value);
			}
			else
			{
				cb.write8(address, cast(ubyte)(value >> 24));
				cb.write8(address + 1, cast(ubyte)(value >> 16));
				cb.write8(address + 2, cast(ubyte)(value >> 8));
				cb.write8(address + 3, cast(ubyte)value);
			}
		}
	}

	uint ServicedRead32_16_LE(uint address)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & BlockFlags.InvalidAccess)
			return InvalidRead(address);

		Read16Handler read16 = callbacks[block.flags >> BlockFlags.CallbackIndex].read16;
		uint value = read16(address);
		value |= cast(uint)read16(address + 2) << 16;
		return value;
	}

	void ServicedWrite32_16_LE(uint address, uint value)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & (BlockFlags.InvalidAccess | BlockFlags.ReadOnly))
			InvalidWrite(address, value);
		else
		{
			Write16Handler write16 = callbacks[block.flags >> BlockFlags.CallbackIndex].write16;
			write16(address, cast(ushort)value);
			write16(address + 2, cast(ushort)(value >> 16));
		}

	}

	uint ServicedRead32_16_BE(uint address)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & BlockFlags.InvalidAccess)
			return InvalidRead(address);

		Read16Handler read16 = callbacks[block.flags >> BlockFlags.CallbackIndex].read16;
		uint value = cast(uint)read16(address) << 16;
		value |= read16(address + 2);
		return value;
	}

	void ServicedWrite32_16_BE(uint address, uint value)
	{
		Block* block = &memory[address >> 8];

		if(block.flags & (BlockFlags.InvalidAccess | BlockFlags.ReadOnly))
			InvalidWrite(address, value);
		else
		{
			Write16Handler write16 = callbacks[block.flags >> BlockFlags.CallbackIndex].write16;
			write16(address, cast(ushort)(value >> 16));
			write16(address + 2, cast(ushort)value);
		}
	}

	ubyte UnMappedIORead(uint address) const pure nothrow
	{
		return 0xFF;
	}

	void UnMappedIOWrite(uint address, ubyte value) const pure nothrow
	{
	}

	MemoryRange GetMemoryRange(uint startAddress, uint endAddress)
	{
		assert(endAddress > startAddress, "Address range is not linear!");

		MemoryRange result;
		foreach(ref r; ranges)
		{
			if(r.start < endAddress && startAddress < r.end)
			{
				if(result)
					assert(false, "collides with multiple ranges");
				else
					result = r;
			}
		}
		return result;
	}

	// machine reference
	Machine machine;

	int addressBits;
	Block memory[];

	MemoryCallbacks callbacks[];

	Read8Handler ioRead;
	Write8Handler ioWrite;

	Read32Handler illegalRead;
	Write32Handler illegalWrite;

	// debug info
	MemoryRange ranges[];
	bool bTrapUndefinedAccess;
}

module demu.emulator.debugger;

import demu.emulator.machine;
import demu.emulator.parts.processor;

enum BreakReason
{
	Unknown,

	Breakpoint,
	HaltInstruction,
	IllegalOpcode,
	IllegalAddress
}

class Debugger
{
	this()
	{

	}

	bool BeginStep(Processor proc, uint pc)
	{
		return false;
	}

	void JumpToSub(Processor proc, uint returnAddress, uint target, int interruptLevel)
	{

	}

	void ReturnFromSub(Processor proc, uint returnTarget)
	{

	}

	void Break(string message, BreakReason reason)
	{
		//...
	}

private:
	Machine machine;
}

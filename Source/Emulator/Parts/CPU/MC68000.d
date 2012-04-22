module demu.emulator.parts.cpu.mc68000;

import demu.emulator.machine;
import demu.emulator.memmap;
import demu.emulator.parts.part;
import demu.emulator.parts.processor;

import std.string;

class MC68000 : Processor
{
	enum Version
	{
		MC68000,   // 16 bit data bus
		MC68008,   // 8 bit data bus
		MC68010,   // some exception handling differences
		MC68012,   // 31 bit address bus
		MC68EC020, // 24bit address bus, may have 68881/2 bolted on the side?
		MC68020,   // 32bit address bus, may have 68881/2 bolted on the side?
		MC68030,   // 32bit address bus, may have 68881/2 bolted on the side?
		MC68040,   // has built in FPU opcodes
		MC68060,   // has built in FPU opcodes
		Max
	}

	this(Machine machine, string name, MemMap memmap, Version processorRevision)
	{
		super(machine, name, Feature.Stack | Feature.Code | Feature.Registers);
		MemoryMap = memmap;

		this.processorRevision = processorRevision;

		procInfo.name = g68kVersionInfo[processorRevision].name;
		procInfo.processorFamily = "680x0";
		procInfo.endian = Endian.Big;
		procInfo.addressWidth = g68kVersionInfo[processorRevision].addressWidth;
		procInfo.addressMask = g68kVersionInfo[processorRevision].addressMask;
		procInfo.stackOffset = 0x0;
		procInfo.opcodeWidth = 16;
		procInfo.maxOpwords = 5;
		procInfo.maxAsmLineLength = 43;

		regInfo = sRegInfo;
		displayRegs = sDisplayRegs;

		// ** UNCOMMENT THIS LINE IF YOU PREFER A REALLY WIDE LISTING ON ONE LINE **
		//displayRegs = sDisplayRegsOnOneLine;

		// 040s and 060s have built in FPUs
		if(processorRevision == Version.MC68040)
		{
			fpuModel = FPU_Model.MC68040;
			fpuID = 1;
		}
		else if(processorRevision == Version.MC68060)
		{
			fpuModel = FPU_Model.MC68060;
			fpuID = 1;
		}
		else
		{
			fpuModel = FPU_Model.None;
			fpuID = -1;
		}

		// assign the instruction timings
		if(processorRevision == Version.MC68010)
		{
			pInstructionCycleCounts = instructionCycleCounts_68010;
			pSpecialInstructionTimings = specialInstructionTimings_68010;
		}
		else
		{
			pInstructionCycleCounts = instructionCycleCounts_68000;
			pSpecialInstructionTimings = specialInstructionTimings_68000;
		}

		// since the address mode has AM_UNK as -1, we make the array one longer and start one element forward to compensate
		pAddressModeCycleCounts = addressModeCycleCounts_68000;

		// pre-020 cpu's only support the brief extension word
		extensionWordMask = processorRevision >= Version.MC68EC020 ? 0xFFFF : 0xF8FF;

		exceptionPending = ExceptionTable.NoException;

		bUseAutoVectorInterrupts = true;
	}

	uint Reset()
	{
		// set supervisor mode, and highest interrupt mask
		regs.sr |= SF_Supervisor;
		regs.sr |= SF_InterruptLevelMask;

		// read the starting PC and stack pointer from vectors
		regs.a[7].l = memmap.Read32_BE_Aligned_16(ExceptionTable.ResetStackPointer * 4);
		regs.pc = memmap.Read32_BE_Aligned_16(ExceptionTable.ResetProgramCounter * 4);
		startAddress = regs.pc;

		return super.Reset();
	}

	void SetProgramCounter(uint pc) nothrow
	{
		regs.pc = pc;
	}

	void SignalBUSERR(uint address)
	{
		// raise BUS ERROR exception
		RaiseException(ExceptionTable.BusErrorException);
	}

	void EnableAutoVectorInterrupts(bool bEnable)
	{
		bUseAutoVectorInterrupts = bEnable;
	}

	void SetIpl(int line, bool state)
	{
		const int bit = (1 << line);
		SignalIRQ(state ? (irqLineState | bit) : (irqLineState & ~bit));
	}

	int Execute(int numCycles, uint breakConditions)
	{
		bYield = false;

		long cycleCount = this.cycleCount;

		int remainingCycles = numCycles;
		do
		{
			waitCycles = 0;

			// check for interrupts
			ushort oldSR = regs.sr; // take a copy of the SR register in case we need to push it to the stack later
			if(irqLineState > 0)
			{
				int intLevel = (regs.sr & SF_InterruptLevelMask) >> 8;

				// 68000 only processes higher level interrupts
				// Level 7 is always processed.
				if(irqLineState > intLevel || irqLineState == 7 )
				{
					// mask the new interrupt level
					regs.sr = (regs.sr & ~SF_InterruptLevelMask) | cast(ushort)(irqLineState << 8);

					// default auto-vector exception
					int vector = ExceptionTable.SpuriousInterruptException + irqLineState;

					// acknowledge the interrupt
					if(intAckHandler)
					{
						uint userVector = intAckHandler(this);

						// if auto-vector interrupts are disabled, raise the exception provided by external logic
						if(!bUseAutoVectorInterrupts)
							vector = cast(int)userVector;
					}

					// raise the interrupt exception
					RaiseException(vector);
				}
			}

			// get starting cycle
			long cc = cycleCount;

			// check for pending exceptions
		handle_exception:
			if(exceptionPending)
			{
				// enter supervisor mode
				if(!(regs.sr & SF_Supervisor))
					EnterSupervisorMode();

				if (processorRevision == Version.MC68010)
				{
					// 68010 pushes the vector (mode 0000)
					Push16(cast(ushort)(exceptionPending << 2));
				}

				// push PC and SR on the supervisor stack
				Push32(regs.pc);
				Push16(oldSR);

				// ** TODO: more recent models of 68000 push a bunch more stuff on the stack... **

				// continue execution from the exception vector
				uint oldPC = regs.pc;
				regs.pc = memmap.Read32_BE_Aligned_16(exceptionPending << 2);

				// allow the debugger to trace the callstack
//				DebugJumpToSub(oldPC, regs.pc, irqLineState);

				exceptionPending = ExceptionTable.NoException;
			}

			// allow the debugger to step the cpu
//			if(DebugBeginStep(regs.pc))
//				break;

			static if(EnableDissassembly)
			{
				// log the instruction stream
				DisassembledOp disOp = void;
				bool bDisOpValid = false;
				if(bLogExecution)
					bDisOpValid = !!DisassembleOpcode(regs.pc, &disOp);
			}

			// read the next op at the program counter
//			TRACK_OPCODE(regs.pc);
			ushort opcode = Read16(regs.pc);
			regs.pc += 2;

			// decode the opcode
			Opcode op = void;
			bool bValidOp = Decode(opcode, op);
			if(!bValidOp)
			{
				// allow the debugger to break on illegal opcodes
//				machine.DebugBreak("Illegal Opcode", BR_IllegalOpcode);

				// HACK: assert here just for dev
				assert(false, "Illegal Opcode!");

				// some opcodes may be emulated in software
				if(opcode >> 12 == 0xA)
				{
					// unimplemented A-Line opcode exception
					RaiseException(ExceptionTable.Line1010EmulatorException);
				}
				else if(opcode >> 12 == 0xF)
				{
					// unimplemented F-Line opcode exception
					RaiseException(ExceptionTable.Line1111EmulatorException);
				}

				// illegal instruction exception
				RaiseException(ExceptionTable.IllegalInstructionException);
			}
			else
			{
				// increment the cpu cycle count
				long instructionCycles = pAddressModeCycleCounts[op.am0] + pAddressModeCycleCounts[op.am1];

				// calculate instruction cycle count
				int size = (op.ds & 2);
				int mem = (((AddressingMode.AReg - (op.am1 != AddressingMode.UNK ? op.am1 : op.am0)) & 0x100) >> 8);
				int index = size | mem;
				instructionCycles += pInstructionCycleCounts[op.op][index];
				//assert(pInstructionCycleCounts[op.op][index] > 0, ">_<");

				// add to the cycle count
				cycleCount += instructionCycles;

				// temps for intermediate values
				uint address0, address1;
				uint operand0, operand1;

				// calculate the operand based on the addressing mode
				switch(op.am0)
				{
					case AddressingMode.DReg:
						operand0 = regs.d[op.d0].l;// & gDSMask[op.ds];
						break;
					case AddressingMode.AReg:
						operand0 = regs.a[op.d0].l;
						break;
					case AddressingMode.Ind:
						address0 = regs.a[op.d0].l;
					fetch_indirect:
						if(op.i0)
						{
							switch(op.ds)
							{
								case DataSize.Byte:
									operand0 = Read8(address0);
									cycleCount += 2;//4;
									break;
								case DataSize.Word:
									operand0 = Read16(address0);
									cycleCount += 2;//4;
									break;
								case DataSize.Long:
									operand0 = Read32(address0);
									cycleCount += 4;//8;
									break;
								default:
									assert(false, "Illegal!");
									break;
							}
						}
						break;
					case AddressingMode.IndPreDec:
						if(op.d0 == 7 && op.ds == DataSize.Byte)
						{
							assert(false, "What horrid code is pushing/popping bytes from the stack?");
							// stack modes through A7 need to remain aligned, so byte access needs to push an extra byte
							Write8(regs.a[op.d0].l - 1, 0);
							address0 = regs.a[op.d0].l - 2;
						}
						else
							address0 = regs.a[op.d0].l - gDSBytes[op.ds];
						regs.a[op.d0].l = address0;
						goto fetch_indirect;
					case AddressingMode.IndPostInc:
						address0 = regs.a[op.d0].l;
						if(op.d0 == 7 && op.ds == DataSize.Byte)
						{
							assert(false, "What horrid code is pushing/popping bytes from the stack?");
							regs.a[op.d0].l += 2; // single byte stack access through A7 remains aligned
						}
						else
							regs.a[op.d0].l += gDSBytes[op.ds];
						goto fetch_indirect;
					case AddressingMode.IndOffset:
						address0 = regs.a[op.d0].l + cast(short)Read16(regs.pc);
						regs.pc += 2;
						goto fetch_indirect;
					case AddressingMode.IndIndex:
						address0 = CalculateIndexedEA(regs.a[op.d0].l);
						goto fetch_indirect;
					case AddressingMode.AbsW:
						address0 = cast(uint)cast(int)cast(short)Read16(regs.pc);
						regs.pc += 2;
						goto fetch_indirect;
					case AddressingMode.AbsL:
						address0 = Read32(regs.pc);
						regs.pc += 4;
						goto fetch_indirect;
					case AddressingMode.OffsetPC:
						address0 = regs.pc + cast(short)Read16(regs.pc);
						regs.pc += 2;
						goto fetch_indirect;
					case AddressingMode.IndexPC:
						address0 = CalculateIndexedEA(regs.pc);
						goto fetch_indirect;
					case AddressingMode.Imm:
						if(op.ds == DataSize.Long)
						{
							operand0 = Read32(regs.pc);
							regs.pc += 4;
							cycleCount += 4;//8;
						}
						else
						{
							case AddressingMode.Imm16:
								operand0 = cast(uint)cast(int)cast(short)Read16(regs.pc);
								regs.pc += 2;
								cycleCount += 2;//4;
						}
						break;
					case AddressingMode.StatusReg:
						operand0 = regs.sr;
						if(processorRevision >= Version.MC68010 && !(regs.sr & SF_Supervisor) && op.ds == DataSize.Word && op.op != Instruction.MC68000_MOVECCR)
						{
							RaiseException(ExceptionTable.PrivilegeViolationException); // privilege violation exception
							goto handle_exception;
						}
						break;
					case AddressingMode.Provided:
						operand0 = op.d0;
						break;
					case AddressingMode.Special:
						assert(false, "Illegal!");
					default:
					case AddressingMode.Implicit:
						break;
				}

				// calculate the operand based on the addressing mode
				switch(op.am1)
				{
					case AddressingMode.DReg:
						operand1 = regs.d.ptr[op.d1].l;// & gDSMask[op.ds];
						break;
					case AddressingMode.AReg:
						operand1 = regs.a[op.d1].l;
						break;
					case AddressingMode.Ind:
						address1 = regs.a[op.d1].l;
					fetch_indirect2:
						if(op.i1)
						{
							switch(op.ds)
							{
								case DataSize.Byte:
									operand1 = Read8(address1);
									cycleCount += 2;//4;
									break;
								case DataSize.Word:
									operand1 = Read16(address1);
									cycleCount += 2;//4;
									break;
								case DataSize.Long:
									operand1 = Read32(address1);
									cycleCount += 4;//8;
									break;
								default:
									assert(false, "Illegal!");
									break;
							}
						}
						break;
					case AddressingMode.IndPreDec:
						if(op.d1 == 7 && op.ds == DataSize.Byte)
						{
							assert(false, "What horrid code is pushing/popping bytes from the stack?");
							// stack modes through A7 need to remain aligned, so byte access needs to push an extra byte
							Write8(regs.a[op.d1].l - 1, 0);
							address1 = regs.a[op.d1].l - 2;
						}
						else
							address1 = regs.a[op.d1].l - gDSBytes[op.ds];
						regs.a[op.d1].l = address1;
						goto fetch_indirect2;
					case AddressingMode.IndPostInc:
						address1 = regs.a[op.d1].l;
						if(op.d1 == 7 && op.ds == DataSize.Byte)
						{
							assert(false, "What horrid code is pushing/popping bytes from the stack?");
							regs.a[op.d1].l += 2; // single byte stack access through A7 remains aligned
						}
						else
							regs.a[op.d1].l += gDSBytes[op.ds];
						goto fetch_indirect2;
					case AddressingMode.IndOffset:
						address1 = regs.a[op.d1].l + cast(short)Read16(regs.pc);
						regs.pc += 2;
						goto fetch_indirect2;
					case AddressingMode.IndIndex:
						address1 = CalculateIndexedEA(regs.a[op.d1].l);
						goto fetch_indirect2;
					case AddressingMode.AbsW:
						address1 = cast(uint)cast(int)cast(short)Read16(regs.pc);
						regs.pc += 2;
						goto fetch_indirect2;
					case AddressingMode.AbsL:
						address1 = Read32(regs.pc);
						regs.pc += 4;
						goto fetch_indirect2;
					case AddressingMode.OffsetPC:
						address1 = regs.pc + cast(short)Read16(regs.pc);
						regs.pc += 2;
						goto fetch_indirect2;
					case AddressingMode.IndexPC:
						address1 = CalculateIndexedEA(regs.pc);
						goto fetch_indirect2;
					case AddressingMode.Imm:
						if(op.ds == DataSize.Long)
						{
							operand1 = Read32(regs.pc);
							regs.pc += 4;
							cycleCount += 4;//8;
						}
						else
						{
							case AddressingMode.Imm16:
								operand1 = cast(uint)cast(int)cast(short)Read16(regs.pc);
								regs.pc += 2;
								cycleCount += 2;//4;
						}
						break;
					case AddressingMode.StatusReg:
						operand1 = regs.sr;
						if(!(regs.sr & SF_Supervisor) && op.ds == DataSize.Word && op.op != Instruction.MC68000_MOVECCR)
						{
							RaiseException(ExceptionTable.PrivilegeViolationException); // privilege violation exception
							goto handle_exception;
						}
						break;
					case AddressingMode.Special:
						assert(false, "Illegal!");
					default:
					case AddressingMode.Implicit:
						break;
				}

				// perform the operation
				switch(op.op)
				{
					case Instruction.MC68000_ABCD:
						ushort x = ((regs.sr >> 4) & 1);

						ushort lowNybble = cast(ubyte)((operand0 & 0xF) + (operand1 & 0xF) + x);
						if(lowNybble > 0x9)
							lowNybble += 0x6;
						ushort result = cast(ubyte)((operand0 & 0xF0) + (operand1 & 0xF0) + lowNybble);
						if((result & 0x1F0) > 0x90)
							result += 0x60;

						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVC(result, operand0, operand1, 8);
						break;
					case Instruction.MC68000_ADDXB:
					case Instruction.MC68000_ADDB:
					case Instruction.MC68000_ADDIB:
						int x = (op.op == Instruction.MC68000_ADDXB && (regs.sr & SF_Extend) ? 1 : 0);

						uint result = cast(ubyte)operand0 + cast(ubyte)operand1 + x;
						if(op.am1 > AddressingMode.AReg)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVC(result, operand0, operand1, 8);
						break;
					case Instruction.MC68000_ADDXW:
					case Instruction.MC68000_ADDW:
					case Instruction.MC68000_ADDIW:
						int x = (op.op == Instruction.MC68000_ADDXW && (regs.sr & SF_Extend) ? 1 : 0);

						uint result = cast(ushort)operand0 + cast(ushort)operand1 + x;
						if(op.am1 > AddressingMode.AReg)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVC(result, operand0, operand1, 16);
						break;
					case Instruction.MC68000_ADDXL:
					case Instruction.MC68000_ADDL:
					case Instruction.MC68000_ADDIL:
						int x = (op.op == Instruction.MC68000_ADDXL && (regs.sr & SF_Extend) ? 1 : 0);

						ulong result = cast(ulong)operand0 + cast(ulong)operand1 + x;
						if(op.am1 > AddressingMode.AReg)
							Write32(address1, cast(uint)result);
						else
							regs.d[op.d1].l = cast(uint)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVC(result, operand0, operand1, 32);
						break;
					case Instruction.MC68000_ADDAW:
						regs.a[op.d1].l += cast(short)cast(ushort)operand0;
						break;
					case Instruction.MC68000_ADDAL:
						regs.a[op.d1].l += cast(int)operand0;
						break;
					case Instruction.MC68000_ANDB:
						uint result = operand0 & operand1;

						switch(op.am1)
						{
							case AddressingMode.DReg:
							case AddressingMode.AReg:
								regs.d[op.d1].b = cast(ubyte)result;
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 8);
								break;
							case AddressingMode.StatusReg:
								regs.sr &= cast(ushort)operand0 | 0xFF00;
								break;
							default:
								Write8(address1, cast(ubyte)result);
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 8);
								break;
						}
						break;
					case Instruction.MC68000_ANDW:
						uint result = operand0 & operand1;

						switch(op.am1)
						{
							case AddressingMode.DReg:
							case AddressingMode.AReg:
								regs.d[op.d1].w = cast(ushort)result;
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 16);
								break;
							case AddressingMode.StatusReg:
								regs.sr &= cast(ushort)operand0;

								// check if we have left supervisor mode
								if(!(regs.sr & SF_Supervisor))
									ExitSupervisorMode();
								break;
							default:
								Write16(address1, cast(ushort)result);
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 16);
								break;
						}
						break;
					case Instruction.MC68000_ANDL:
						uint result = operand0 & operand1;

						if(op.am1 > AddressingMode.AReg)
							Write32(address1, result);
						else
							regs.d[op.d1].l = result;

						regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 32);
						break;
					case Instruction.MC68000_ASLB:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						uint result = operand1 << operand0;
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 8);
						// TODO: WE NEED TO SET THE V BIT TO TEST FOR OVERFLOW!!
						break;
					case Instruction.MC68000_ASLW:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						uint result = operand1 << operand0;
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 16);
						// TODO: WE NEED TO SET THE V BIT TO TEST FOR OVERFLOW!!
						break;
					case Instruction.MC68000_ASLL:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						ulong result = operand1 << operand0;
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, cast(uint)result);
						else
							regs.d[op.d1].l = cast(uint)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 32);
						// TODO: WE NEED TO SET THE V BIT TO TEST FOR OVERFLOW!!
						break;
					case Instruction.MC68000_ASRB:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						ulong result = ((cast(ubyte)operand1 >>> operand0) & 0xFF) | ((operand1 << (9 - operand0)) & 0x100);
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 8);
						break;
					case Instruction.MC68000_ASRW:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						ulong result = ((cast(ushort)operand1 >>> operand0) & 0xFFFF) | ((operand1 << (17 - operand0)) & 0x10000);
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 16);
						break;
					case Instruction.MC68000_ASRL:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						ulong result = ((cast(uint)operand1 >>> operand0) & 0xFFFFFFFF) | ((operand1 << (33 - operand0)) & 0x100000000);
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, cast(uint)result);
						else
							regs.d[op.d1].l = cast(uint)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 32);
						break;
					case Instruction.MC68000_BCHG:
						regs.sr |= SF_Zero;
						if(op.am1 >= AddressingMode.Ind)
						{
							operand0 = 1 << (operand0 & 0x7);
							Write8(address1, cast(ubyte)(operand1 ^ operand0));
						}
						else
						{
							operand0 = 1 << (operand0 & 0x1F);
							regs.d[op.d1].l = operand1 ^ operand0;
						}
						if(operand1 & operand0)
							regs.sr ^= SF_Zero;
						break;
					case Instruction.MC68000_BCLR:
						regs.sr |= SF_Zero;
						if(op.am1 >= AddressingMode.Ind)
						{
							operand0 = 1 << (operand0 & 0x7);
							Write8(address1, cast(ubyte)(operand1 & ~operand0));
						}
						else
						{
							operand0 = 1 << (operand0 & 0x1F);
							regs.d[op.d1].l = operand1 & ~operand0;
						}
						if(operand1 & operand0)
							regs.sr ^= SF_Zero;
						break;
					case Instruction.MC68000_BSET:
						regs.sr |= SF_Zero;
						if(op.am1 >= AddressingMode.Ind)
						{
							operand0 = 1 << (operand0 & 0x7);
							Write8(address1, cast(ubyte)(operand1 | operand0));
						}
						else
						{
							operand0 = 1 << (operand0 & 0x1F);
							regs.d[op.d1].l = operand1 | operand0;
						}
						if(operand1 & operand0)
							regs.sr ^= SF_Zero;
						break;
					case Instruction.MC68000_BTST:
						regs.sr |= SF_Zero;
						operand0 = 1 << (operand0 & (op.am1 >= AddressingMode.Ind ? 0x7 : 0x1F));
						if(operand0 & operand1)
							regs.sr ^= SF_Zero;
						break;
					case Instruction.MC68000_BHI: //CND_High
						if ((regs.sr & (SF_Carry | SF_Zero)) == 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BLS: //CND_LowOrSame
						if ((regs.sr & (SF_Carry | SF_Zero)) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BCC: //CND_CarryClear
						if ((regs.sr & SF_Carry) == 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BCS: //CND_CarrySet
						if ((regs.sr & SF_Carry) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BEQ: //CND_Equal
						if ((regs.sr & SF_Zero) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BNE: //CND_NotEqual
						if ((regs.sr & SF_Zero) == 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BVC: //CND_OverflowClear
						if ((regs.sr & SF_Overflow) == 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BVS: //CND_OverflowSet
						if ((regs.sr & SF_Overflow) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BPL: //CND_Plus
						if ((regs.sr & SF_Negative) == 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BMI: //CND_Minus
						if ((regs.sr & SF_Negative) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BGE: //CND_GreaterOrEqual
						// Added by Stu. N & V | /N & /V needs optimizing
						ubyte n, v;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						if (((n & v) | ((n^1) & (v^1))) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BLT: //CND_LessThan
						// Added by Stu. N & /V | /N & V needs optimizing
						ubyte n, v;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						if (((n && !v) || (!n && v)) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BGT: //CND_GreaterThan
						// Added by Stu. (N&V&/Z) + (/N&/V&/Z) needs optimizing
						ubyte n, v, z;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						z = (regs.sr & SF_Zero) >> 2;
						if (((n & v & (z^1)) | ((n^1) & (v^1) & (z^1))) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BLE: //CND_LessOrEqual
						// Added by Stu. Z + (N&/V) + (/N&V) needs optimizing
						ubyte n, v, z;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						z = (regs.sr & SF_Zero) >> 2;
						if (((z | (n & (v^1)) | ((n^1) & v))) != 0)
							goto __BccTrue;
						goto __BccFalse;
					case Instruction.MC68000_BSR:
						// BSR ** Note: Bcc uses the 'false' condition here
						// allow the debugger to track the callstack
//						DebugJumpToSub(regs.pc, regs.pc + cast(int)operand0, (regs.sr & SF_InterruptLevelMask) >> 8);

						// push the PC on the stack
						Push32(regs.pc);
						// adjust relative address offset          break;
					case Instruction.MC68000_BRA:
					__BccTrue:
						// there are some slight offsets depending on the addressing mode...
						switch(op.am0)
						{
							case AddressingMode.Imm16:
								regs.pc += operand0 - 2;
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Bcc_Taken];
								break;
							case AddressingMode.Imm:
								regs.pc += operand0 - 4;
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Bcc_Taken];
								break;
							default:
								regs.pc += operand0;
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Bcc_Taken];
								break;
						}
						break;
					__BccFalse:
						switch(op.am0)
						{
							case AddressingMode.Imm16:
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Bcc_W_NotTaken];
								break;
							case AddressingMode.Imm:
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Bcc_L_NotTaken];
								break;
							default:
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Bcc_B_NotTaken];
								break;
						}
						break;
					case Instruction.MC68000_CHK:
						assert(false, "WRITE ME!");
						break;
					case Instruction.MC68000_CLRB:
						regs.sr = (regs.sr & 0xFFF0) | SF_Zero;
						if(op.am0 >= AddressingMode.Ind)
							Write8(address0, 0);
						else
							regs.d[op.d0].b = 0;
						break;
					case Instruction.MC68000_CLRW:
						regs.sr = (regs.sr & 0xFFF0) | SF_Zero;
						if(op.am0 >= AddressingMode.Ind)
							Write16(address0, 0);
						else
							regs.d[op.d0].w = 0;
						break;
					case Instruction.MC68000_CLRL:
						regs.sr = (regs.sr & 0xFFF0) | SF_Zero;
						if(op.am0 >= AddressingMode.Ind)
							Write32(address0, 0);
						else
							regs.d[op.d0].l = 0;
						break;
					case Instruction.MC68000_CMPB:
						int result = cast(ubyte)operand1 - cast(ubyte)operand0;
						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZVnC(result, operand1, operand0, 8);
						break;
					case Instruction.MC68000_CMPW:
						int result = cast(ushort)operand1 - cast(ushort)operand0;
						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZVnC(result, operand1, operand0, 16);
						break;
					case Instruction.MC68000_CMPL:
						long result = cast(ulong)operand1 - cast(ulong)operand0;
						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZVnC(result, operand1, operand0, 32);
						break;
					case Instruction.MC68000_CMPA:
						if(op.ds == DataSize.Word)
						{
							// the hardware sign extends the operands for the comparison, but is it actually necessary???
							// i think a 16 bit comparison in this case would be identical? this is probably redundant work...
							op.ds = DataSize.Long;
							operand0 = cast(uint)cast(int)cast(short)cast(ushort)operand0;
							operand1 = cast(uint)cast(int)cast(short)cast(ushort)operand1;
						}
					case Instruction.MC68000_CMPM:
						regs.sr &= 0xFFF0;

						switch(op.ds)
						{
							case DataSize.Byte:
							{
								int result = cast(ubyte)operand1 - cast(ubyte)operand0;
								regs.sr |= FLAG_NZVnC(result, operand1, operand0, 8);
								break;
							}
							case DataSize.Word:
							{
								int result = cast(ushort)operand1 - cast(ushort)operand0;
								regs.sr |= FLAG_NZVnC(result, operand1, operand0, 16);
								break;
							}
							case DataSize.Long:
							{
								long result = cast(ulong)operand1 - cast(ulong)operand0;
								regs.sr |= FLAG_NZVnC(result, operand1, operand0, 32);
								break;
							}
							default:
								break;
						}
						break;
					case Instruction.MC68000_DBHI: //CND_High
						if ((regs.sr & (SF_Carry | SF_Zero)) == 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBLS: //CND_LowOrSame
						if ((regs.sr & (SF_Carry | SF_Zero)) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBCC: //CND_CarryClear
						if ((regs.sr & SF_Carry) == 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBCS: //CND_CarrySet
						if ((regs.sr & SF_Carry) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBEQ: //CND_Equal
						if ((regs.sr & SF_Zero) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBNE: //CND_NotEqual
						if ((regs.sr & SF_Zero) == 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBVC: //CND_OverflowClear
						if ((regs.sr & SF_Overflow) == 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBVS: //CND_OverflowSet
						if ((regs.sr & SF_Overflow) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBPL: //CND_Plus
						if ((regs.sr & SF_Negative) == 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBMI: //CND_Minus
						if ((regs.sr & SF_Negative) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBGE: //CND_GreaterOrEqual
						// Added by Stu. N & V | /N & /V needs optimizing
						ubyte n, v;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						if (((n & v) | ((n^1) & (v^1))) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBLT: //CND_LessThan
						// Added by Stu. N & /V | /N & V needs optimizing
						ubyte n, v;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						if (((n && !v) || (!n && v)) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBGT: //CND_GreaterThan
						// Added by Stu. (N&V&/Z) + (/N&/V&/Z) needs optimizing
						ubyte n, v, z;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						z = (regs.sr & SF_Zero) >> 2;
						if (((n & v & (z^1)) | ((n^1) & (v^1) & (z^1))) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBLE: //CND_LessOrEqual
						// Added by Stu. Z + (N&/V) + (/N&V) needs optimizing
						ubyte n, v, z;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						z = (regs.sr & SF_Zero) >> 2;
						if (((z | (n & (v^1)) | ((n^1) & v))) != 0)
							goto __DBccTrue;
						goto __DBccFalse;
					case Instruction.MC68000_DBT:
					__DBccTrue:
						cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.DBcc_ccTrue];
						break;
					case Instruction.MC68000_DBF:
					__DBccFalse:
						if(regs.d[op.d0].w != 0)
						{
							regs.pc += operand1 - 2;
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.DBcc_ccFalse_NotExpired];
						}
						else
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.DBcc_ccFalse_Expired];

						--regs.d[op.d0].w;
						break;
					case Instruction.MC68000_DIVS:
						if(operand0 == 0)
						{
							// divide by zero exception
							RaiseException(ExceptionTable.DivideByZeroException);
							break;
						}

						regs.sr &= 0xFFF0;

						uint reg = regs.d[op.d1].l;
						if(INT_ABS16(reg >> 16) >= INT_ABS16(cast(ushort)operand0))
							regs.sr |= SF_Overflow;
						else
						{
							uint result = cast(int)reg / cast(short)cast(ushort)operand0;
							uint remainder = cast(int)reg % cast(short)cast(ushort)operand0;

							regs.d[op.d1].l = (result & 0xFFFF) | (remainder << 16);
							regs.sr |= FLAG_NZ(result, 16);
						}
						break;
					case Instruction.MC68000_DIVU:
						if(operand0 == 0)
						{
							// divide by zero exception
							RaiseException(ExceptionTable.DivideByZeroException);
							break;
						}

						regs.sr &= 0xFFF0;

						if((regs.d[op.d1].l >> 16) >= operand0)
							regs.sr |= SF_Overflow;
						else
						{
							uint result = regs.d[op.d1].l / cast(ushort)operand0;
							uint remainder = regs.d[op.d1].l % cast(ushort)operand0;

							regs.d[op.d1].l = (result & 0xFFFF) | (remainder << 16);
							regs.sr |= FLAG_NZ(result, 16);
						}
						break;
					case Instruction.MC68000_EORB:
						uint result = operand0 ^ operand1;
						switch(op.am1)
						{
							case AddressingMode.DReg:
							case AddressingMode.AReg:
								regs.d[op.d1].b = cast(ubyte)result;
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 8);
								break;
							case AddressingMode.StatusReg:
								regs.sr ^= cast(ushort)operand0 & 0xFF;
								break;
							default:
								Write8(address1, cast(ubyte)result);
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 8);
								break;
						}
						break;
					case Instruction.MC68000_EORW:
						uint result = operand0 ^ operand1;
						switch(op.am1)
						{
							case AddressingMode.DReg:
							case AddressingMode.AReg:
								regs.d[op.d1].w = cast(ushort)result;
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 16);
								break;
							case AddressingMode.StatusReg:
								regs.sr ^= cast(ushort)operand0;

								// check if we have left supervisor mode
								if(!(regs.sr & SF_Supervisor))
									ExitSupervisorMode();
								break;
							default:
								Write16(address1, cast(ushort)result);
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 16);
								break;
						}
						break;
					case Instruction.MC68000_EORL:
						uint result = operand0 ^ operand1;
						if(op.am1 > AddressingMode.AReg)
							Write32(address1, result);
						else
							regs.d[op.d1].l = result;
						regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 32);
						break;
					case Instruction.MC68000_EXG:
						regs.d[op.d0].l = operand1;
						regs.d[op.d1].l = operand0;
						break;
					case Instruction.MC68000_EXT:
						regs.sr &= 0xFFF0;
						if(op.ds == DataSize.Word)
						{
							regs.d[op.d0].w = cast(ushort)cast(short)cast(byte)regs.d[op.d0].b;
							regs.sr |= FLAG_NZ(regs.d[op.d0].w, 16);
						}
						else
						{
							regs.d[op.d0].l = cast(uint)cast(int)cast(short)regs.d[op.d0].w;
							regs.sr |= FLAG_NZ(regs.d[op.d0].l, 32);
						}
						break;
					case Instruction.MC68000_ILLEGAL:
						// illegal instruction exception
						RaiseException(ExceptionTable.IllegalInstructionException);
						break;
					case Instruction.MC68000_JMP:
						regs.pc = address0;
						break;
					case Instruction.MC68000_JSR:
						// allow the debugger to track the callstack
//						DebugJumpToSub(regs.pc, address0, (regs.sr & SF_InterruptLevelMask) >> 8);

						Push32(regs.pc);
						regs.pc = address0;
						break;
					case Instruction.MC68000_LEA:
						regs.a[op.d1].l = address0;
						break;
					case Instruction.MC68000_LINK:
						Push32(regs.a[op.d0].l);
						regs.a[op.d0].l = regs.a[7].l;
						regs.a[7].l += cast(short)operand1;
						break;
					case Instruction.MC68000_LSLB:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						uint result = operand1 << operand0;
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 8);
						break;
					case Instruction.MC68000_LSLW:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						uint result = operand1 << operand0;
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 16);
						break;
					case Instruction.MC68000_LSLL:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						ulong result = cast(ulong)operand1 << operand0;
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, cast(uint)result);
						else
							regs.d[op.d1].l = cast(uint)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 32);
						break;
					case Instruction.MC68000_LSRB:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						uint result = (operand1 & 0xFF) >> operand0;
						result |= (operand1 << (9 - operand0)) & 0x100;
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 8);
						break;
					case Instruction.MC68000_LSRW:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						uint result = (operand1 & 0xFFFF) >> operand0;
						result |= (operand1 << (17 - operand0)) & 0x10000;
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 16);
						break;
					case Instruction.MC68000_LSRL:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						ulong result = operand1 >> operand0;
						result |= (cast(ulong)operand1 << (33 - operand0)) & 0x100000000;
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, cast(uint)result);
						else
							regs.d[op.d1].l = cast(uint)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 32);
						break;
					case Instruction.MC68000_MOVEAW:
						regs.a[op.d1].l = cast(uint)cast(int)cast(short)operand0;
						break;
					case Instruction.MC68000_MOVEAL:
						regs.a[op.d1].l = operand0;
						break;
					case Instruction.MC68000_MOVEB:
						if(op.am1 > AddressingMode.AReg)
							Write8(address1, cast(ubyte)operand0);
						else
							regs.d[op.d1].b = cast(ubyte)operand0;
						regs.sr = FLAG_NZ(operand0, 8) | (regs.sr & 0xFFF0);
						break;
					case Instruction.MC68000_MOVEW:
						if(op.am1 > AddressingMode.AReg)
							Write16(address1, cast(ushort)operand0);
						else
							regs.d[op.d1].w = cast(ushort)operand0;
						regs.sr = FLAG_NZ(operand0, 16) | (regs.sr & 0xFFF0);
						break;
					case Instruction.MC68000_MOVEL:
						if(op.am1 > AddressingMode.AReg)
							Write32(address1, operand0);
						else
							regs.d[op.d1].l = operand0;
						regs.sr = FLAG_NZ(operand0, 32) | (regs.sr & 0xFFF0);
						break;
					case Instruction.MC68000_MOVEM:
						Registers.Register* pRegs = regs.d.ptr;

						int oldAddress = address1;
						if(opcode & 0x400)
						{
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVEM_Load];

							// load regs
							if(op.ds == DataSize.Word)
							{
								address1 -= 2;
								foreach(a; 0..16)
								{
									if(operand0 & 1)
									{
										address1 += 2;
										pRegs[a].w = Read16(address1);
										cycleCount += 4;
									}
									operand0 >>= 1;
								}
								address1 += 2;
							}
							else
							{
								address1 -= 4;
								foreach(a; 0..16)
								{
									if(operand0 & 1)
									{
										address1 += 4;
										pRegs[a].l = Read32(address1);
										cycleCount += 8;
									}
									operand0 >>= 1;
								}
								address1 += 4;
							}

							if(op.am1 == AddressingMode.IndPreDec || op.am1 == AddressingMode.IndPostInc)
								regs.a[op.d1&7].l = address1;
						}
						else
						{
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVEM_Store];

							// store regs
							if(op.am1 == AddressingMode.IndPreDec)
							{
								// store in reverse order
								if(op.ds == DataSize.Word)
								{
									address1 += 2;
									for(int a=15; a>=0; --a)
									{
										if(operand0 & 1)
										{
											address1 -= 2;
											Write16(address1, pRegs[a].w);
											cycleCount += 4;
										}
										operand0 >>= 1;
									}
								}
								else
								{
									address1 += 4;
									for(int a=15; a>=0; --a)
									{
										if(operand0 & 1)
										{
											address1 -= 4;
											Write32(address1, pRegs[a].l);
											cycleCount += 8;
										}
										operand0 >>= 1;
									}
								}
							}
							else
							{
								// store in normal order
								if(op.ds == DataSize.Word)
								{
									foreach(a; 0..16)
									{
										if(operand0 & 1)
										{
											Write16(address1, pRegs[a].w);
											address1 += 2;
											cycleCount += 4;
										}
										operand0 >>= 1;
									}
								}
								else
								{
									foreach(a; 0..16)
									{
										if(operand0 & 1)
										{
											Write32(address1, pRegs[a].l);
											address1 += 4;
											cycleCount += 8;
										}
										operand0 >>= 1;
									}
								}
							}

							if(op.am1 == AddressingMode.IndPreDec || op.am1 == AddressingMode.IndPostInc)
								regs.a[op.d1&7].l = address1;
						}
						break;
					case Instruction.MC68000_MOVEP:
						if(opcode & 0x80)
						{
							// store to peripheral
							if(op.ds == DataSize.Word)
							{
								Write8(address1, cast(ubyte)((operand0 >> 8) & 0xFF));
								Write8(address1 + 2, cast(ubyte)(operand0 & 0xFF));
							}
							else
							{
								Write8(address1, cast(ubyte)(operand0 >> 24));
								Write8(address1 + 2, cast(ubyte)((operand0 >> 16) & 0xFF));
								Write8(address1 + 4, cast(ubyte)((operand0 >> 8) & 0xFF));
								Write8(address1 + 6, cast(ubyte)(operand0 & 0xFF));
							}
						}
						else
						{
							// load from peripheral
							if(op.ds == DataSize.Word)
							{
								ushort result = (cast(ushort)Read8(address0) << 8)
									| cast(ushort)Read8(address0 + 2);
								regs.d[op.d1].w = result;
							}
							else
							{
								uint result = (cast(uint)Read8(address0) << 24)
									| (cast(uint)Read8(address0 + 2) << 16)
									| (cast(uint)Read8(address0 + 4) << 8)
									| cast(uint)Read8(address0 + 6);
								regs.d[op.d1].l = result;
							}
						}
						break;
					case Instruction.MC68000_MOVEQ:
						regs.d[op.d1].l = op.d0;
						regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(regs.d[op.d1].l, 32);
						break;
					case Instruction.MC68000_MOVEUSP:
						if(!(regs.sr & SF_Supervisor))
						{
							// privilege violation exception
							RaiseException(ExceptionTable.PrivilegeViolationException);
							goto handle_exception;
						}

						if(opcode & 8)
						{
							regs.a[op.d1].l = regs.usp;
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVEUSP_USP2Reg];
						}
						else
						{
							regs.usp = regs.a[op.d0].l;
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVEUSP_Reg2USP];
						}
						break;
					case Instruction.MC68000_MOVECCR:
						switch(op.am1)
						{
							case AddressingMode.DReg:
								regs.d[op.d1].b = cast(ubyte)operand0;
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVESR_SR2Reg];
								break;
							case AddressingMode.StatusReg:
								regs.sr = (regs.sr & 0xFF00) | cast(ubyte)(operand0 & 0xFF);
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVESR_ToSR];
								break;
							default:
								Write8(address1, cast(ubyte)operand0);
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVESR_SR2Mem];
								break;
						}
						break;
					case Instruction.MC68000_MOVESR:
						switch(op.am1)
						{
							case AddressingMode.DReg:
								regs.d[op.d1].w = cast(ushort)operand0;
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVESR_SR2Reg];
								break;
							case AddressingMode.StatusReg:
								regs.sr = cast(ushort)operand0;
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVESR_ToSR];

								// check if we have left supervisor mode
								if(!(regs.sr & SF_Supervisor))
									ExitSupervisorMode();
								break;
							default:
								Write16(address1, cast(ushort)operand0);
								cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.MOVESR_SR2Mem];
								break;
						}
						break;
					case Instruction.MC68000_MULS:
						regs.sr &= 0xFFF0;
						regs.d[op.d1].l = cast(uint)(cast(int)cast(short)regs.d[op.d1].w * cast(int)cast(short)cast(ushort)operand0);
						regs.sr |= FLAG_NZ(regs.d[op.d1].l, 32);
						break;
					case Instruction.MC68000_MULU:
						regs.sr &= 0xFFF0;
						regs.d[op.d1].l = regs.d[op.d1].w * cast(ushort)operand0;
						regs.sr |= FLAG_NZ(regs.d[op.d1].l, 32);
						break;
					case Instruction.MC68000_NBCD:
						ushort x = ((regs.sr >> 4) & 1);

						ushort result = cast(ushort)(0 - cast(ubyte)operand0 - x);

						// adjust result
						if((result & 0xF) + x)
							result -= 0x6;
						if(result & 0x100)
							result = cast(ushort)((result - 0x60) | 0x100);
						else
							result &= 0xFF;

						// store result and update flags
						if(op.am0 >= AddressingMode.Ind)
							Write8(address0, cast(ubyte)result);
						else
							regs.d[op.d0].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVnC(result, 0u, operand0, 8);
						break;
					case Instruction.MC68000_NEGB:
					case Instruction.MC68000_NEGXB:
						long result = 0 - operand0 - (op.op == Instruction.MC68000_NEGXB && ((regs.sr >> 4) & 1));

						if(op.am0 >= AddressingMode.Ind)
							Write8(address0, cast(ubyte)result);
						else
							regs.d[op.d0].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVnC(result, 0u, operand0, 8);
						break;
					case Instruction.MC68000_NEGW:
					case Instruction.MC68000_NEGXW:
						long result = 0 - operand0 - (op.op == Instruction.MC68000_NEGXW && ((regs.sr >> 4) & 1));

						if(op.am0 >= AddressingMode.Ind)
							Write16(address0, cast(ushort)result);
						else
							regs.d[op.d0].w = cast(ushort)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVnC(result, 0u, operand0, 16);
						break;
					case Instruction.MC68000_NEGL:
					case Instruction.MC68000_NEGXL:
						long result = 0 - operand0 - (op.op == Instruction.MC68000_NEGXL && ((regs.sr >> 4) & 1));

						if(op.am0 >= AddressingMode.Ind)
							Write32(address0, cast(uint)result);
						else
							regs.d[op.d0].l = cast(uint)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVnC(result, 0u, operand0, 32);
						break;
					case Instruction.MC68000_NOP:
						// do nothing...
						break;
					case Instruction.MC68000_NOTB:
						uint result = ~operand0;

						if(op.am0 >= AddressingMode.Ind)
							Write8(address0, cast(ubyte)result);
						else
							regs.d[op.d0].b = cast(ubyte)result;

						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZ(result, 8);
						break;
					case Instruction.MC68000_NOTW:
						uint result = ~operand0;

						if(op.am0 >= AddressingMode.Ind)
							Write16(address0, cast(ushort)result);
						else
							regs.d[op.d0].w = cast(ushort)result;

						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZ(result, 16);
						break;
					case Instruction.MC68000_NOTL:
						uint result = ~operand0;

						if(op.am0 >= AddressingMode.Ind)
							Write32(address0, result);
						else
							regs.d[op.d0].l = result;

						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZ(result, 32);
						break;
					case Instruction.MC68000_ORB:
						uint result = operand0 | operand1;

						switch(op.am1)
						{
							case AddressingMode.DReg:
							case AddressingMode.AReg:
								regs.d[op.d1].b = cast(ubyte)result;
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 8);
								break;
							case AddressingMode.StatusReg:
								regs.sr |= cast(ushort)operand0 & 0xFF;
								break;
							default:
								Write8(address1, cast(ubyte)result);
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 8);
								break;
						}
						break;
					case Instruction.MC68000_ORW:
						uint result = operand0 | operand1;

						switch(op.am1)
						{
							case AddressingMode.DReg:
							case AddressingMode.AReg:
								regs.d[op.d1].w = cast(ushort)result;
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 16);
								break;
							case AddressingMode.StatusReg:
								regs.sr |= cast(ushort)operand0;
								break;
							default:
								Write16(address1, cast(ushort)result);
								regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 16);
								break;
						}
						break;
					case Instruction.MC68000_ORL:
						uint result = operand0 | operand1;

						if(op.am1 > AddressingMode.AReg)
							Write32(address1, result);
						else
							regs.d[op.d1].l = result;

						regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(result, 32);
						break;
					case Instruction.MC68000_PEA:
						Push32(address0);
						break;
					case Instruction.MC68000_RESET:
						if(!(regs.sr & SF_Supervisor))
						{
							// privilege violation exception
							RaiseException(ExceptionTable.PrivilegeViolationException);
							goto handle_exception;
						}

						// call the user reset callback signaling to reset all connected devices
						if(resetHandler)
							resetHandler(this);
						break;
					case Instruction.MC68000_ROLB:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						operand1 &= 0xFF;
						uint result = ((operand1 << operand0) | (operand1 >> (8 - operand0)));
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFF0;  // clear flags
						regs.sr |= FLAG_NZ(result, 8) | (result & SF_Carry);
						break;
					case Instruction.MC68000_ROLW:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						operand1 &= 0xFFFF;
						uint result = ((operand1 << operand0) | (operand1 >> (16 - operand0)));
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFF0;  // clear flags
						regs.sr |= FLAG_NZ(result, 16) | (result & SF_Carry);
						break;
					case Instruction.MC68000_ROLL:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						uint result = ((operand1 << operand0) | (operand1 >> (32 - operand0)));
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, result);
						else
							regs.d[op.d1].l = result;

						regs.sr &= 0xFFF0;  // clear flags
						regs.sr |= FLAG_NZ(result, 32) | (result & SF_Carry);
						break;
					case Instruction.MC68000_RORB:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						operand1 &= 0xFF;
						uint result = (operand1 >> operand0) | (operand1 << (8 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFF0;  // clear flags
						regs.sr |= FLAG_NZ(result, 8) | ((result >> 7) & SF_Carry);
						break;
					case Instruction.MC68000_RORW:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						operand1 &= 0xFFFF;
						uint result = (operand1 >> operand0) | (operand1 << (16 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFF0;  // clear flags
						regs.sr |= FLAG_NZ(result, 16) | ((result >> 7) & SF_Carry);
						break;
					case Instruction.MC68000_RORL:
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						uint result = (operand1 >> operand0) | (operand1 << (32 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, result);
						else
							regs.d[op.d1].l = result;

						regs.sr &= 0xFFF0;  // clear flags
						regs.sr |= FLAG_NZ(result, 32) | ((result >> 7) & SF_Carry);
						break;
					case Instruction.MC68000_ROXLB:
						uint x = (regs.sr & SF_Extend) >> 4;
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						operand1 &= 0xFF;
						uint result = (operand1 << operand0) | (x << (operand0 - 1)) | (operand1 >> (9 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 8);
						break;
					case Instruction.MC68000_ROXLW:
						uint x = (regs.sr & SF_Extend) >> 4;
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						operand1 &= 0xFFFF;
						uint result = (operand1 << operand0) | (x << (operand0 - 1)) | (operand1 >> (17 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 16);
						break;
					case Instruction.MC68000_ROXLL:
						uint x = (regs.sr & SF_Extend) >> 4;
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						ulong result = (cast(ulong)operand1 << operand0) | (x << (operand0 - 1)) | (operand1 >> (33 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, cast(uint)result);
						else
							regs.d[op.d1].l = cast(uint)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 32);
						break;
					case Instruction.MC68000_ROXRB:
						uint x = (regs.sr & SF_Extend) >> 4;
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						operand1 &= 0xFF;
						uint result = (operand1 >> operand0) | (x << (8 - operand0)) | (operand1 << (9 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 8);
						break;
					case Instruction.MC68000_ROXRW:
						uint x = (regs.sr & SF_Extend) >> 4;
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						operand1 &= 0xFFFF;
						uint result = (operand1 >> operand0) | (x << (16 - operand0)) | (operand1 << (17 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 16);
						break;
					case Instruction.MC68000_ROXRL:
						uint x = (regs.sr & SF_Extend) >> 4;
						operand0 &= 0x3F;   // shift/rotate is modulo 64
						cycleCount += operand0*2;

						ulong result = (operand1 >> operand0) | (cast(ulong)x << (32 - operand0)) | (cast(ulong)operand1 << (33 - operand0));
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, cast(uint)result);
						else
							regs.d[op.d1].l = cast(uint)result;

						regs.sr &= 0xFFE0;  // clear flags
						regs.sr |= FLAG_XNZC(result, 32);
						break;
					case Instruction.MC68000_RTE:
						if(!(regs.sr & SF_Supervisor))
						{
							// privilege violation exception
							RaiseException(ExceptionTable.PrivilegeViolationException);
							goto handle_exception;
						}

						// restore SR and PC
						regs.sr = Pop16();
						regs.pc = Pop32();

						if (processorRevision == Version.MC68010)
						{
							// 68010 (mode 0000) has the vector on the stack
							Pop16();
						}

						// exit supervisor mode
						if(!(regs.sr & SF_Supervisor))
							ExitSupervisorMode();

						// allow the debugger to track the callstack
//						DebugReturnFromSub(regs.pc);
						break;
					case Instruction.MC68000_RTR:
						// restore CCR and PC
						regs.sr = (regs.sr & 0xFF00) | (Pop16() & 0xFF);
						regs.pc = Pop32();

						// allow the debugger to track the callstack
//						DebugReturnFromSub(regs.pc);
						break;
					case Instruction.MC68000_RTS:
						// restore PC
						regs.pc = Pop32();

						// allow the debugger to track the callstack
//						DebugReturnFromSub(regs.pc);
						break;
					case Instruction.MC68000_SBCD:
						ushort x = ((regs.sr >> 4) & 1);
						ushort result = cast(ushort)(cast(ubyte)operand1 - cast(ubyte)operand0 - x);

						// adjust result
						if((result & 0xF) + x > (cast(ushort)operand1 & 0xF))
							result -= 0x6;
						if(result & 0x100)
							result = cast(ushort)((result - 0x60) | 0x100);
						else
							result &= 0xFF;

						// store result and update flags
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVnC(result, operand1, operand0, 8);
						break;
					case Instruction.MC68000_SHI: //CND_High
						if ((regs.sr & (SF_Carry | SF_Zero)) == 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SLS: //CND_LowOrSame
						if ((regs.sr & (SF_Carry | SF_Zero)) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SCC: //CND_CarryClear
						if ((regs.sr & SF_Carry) == 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SCS: //CND_CarrySet
						if ((regs.sr & SF_Carry) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SEQ: //CND_Equal
						if ((regs.sr & SF_Zero) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SNE: //CND_NotEqual
						if ((regs.sr & SF_Zero) == 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SVC: //CND_OverflowClear
						if ((regs.sr & SF_Overflow) == 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SVS: //CND_OverflowSet
						if ((regs.sr & SF_Overflow) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SPL: //CND_Plus
						if ((regs.sr & SF_Negative) == 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SMI: //CND_Minus
						if ((regs.sr & SF_Negative) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SGE: //CND_GreaterOrEqual
						// Added by Stu. N & V | /N & /V needs optimizing
						ubyte n, v;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						if (((n & v) | ((n^1) & (v^1))) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SLT: //CND_LessThan
						// Added by Stu. N & /V | /N & V needs optimizing
						ubyte n, v;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						if (((n && !v) || (!n && v)) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SGT: //CND_GreaterThan
						// Added by Stu. (N&V&/Z) + (/N&/V&/Z) needs optimizing
						ubyte n, v, z;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						z = (regs.sr & SF_Zero) >> 2;
						if (((n & v & (z^1)) | ((n^1) & (v^1) & (z^1))) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_SLE: //CND_LessOrEqual
						// Added by Stu. Z + (N&/V) + (/N&V) needs optimizing
						ubyte n, v, z;
						n = (regs.sr & SF_Negative) >> 3;
						v = (regs.sr & SF_Overflow) >> 1;
						z = (regs.sr & SF_Zero) >> 2;
						if (((z | (n & (v^1)) | ((n^1) & v))) != 0)
							goto __SccTrue;
						goto __SccFalse;
					case Instruction.MC68000_ST:
					__SccTrue:
						if(op.am1 >= AddressingMode.Ind)
						{
							Write8(address1, 0xFF);
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Scc_ccTrue_Mem];
						}
						else
						{
							regs.d[op.d1].b = 0xFF;
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Scc_ccTrue_Reg];
						}
						break;
					case Instruction.MC68000_SF:
					__SccFalse:
						if(op.am1 >= AddressingMode.Ind)
						{
							Write8(address1, 0);
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Scc_ccFalse_Mem];
						}
						else
						{
							regs.d[op.d1].b = 0;
							cycleCount += pSpecialInstructionTimings[SpecialInstructionTimings.Scc_ccFalse_Reg];
						}
						break;
					case Instruction.MC68000_STOP:
						if(!(regs.sr & SF_Supervisor))
						{
							// privilege violation exception
							RaiseException(ExceptionTable.PrivilegeViolationException);
							goto handle_exception;
						}

						// copy the immediate data to the status register
						regs.sr = cast(ushort)operand0;

						if(!(regs.sr & SF_Supervisor))
							ExitSupervisorMode();

						// point the PC back to the start of the STOP instruction (repeat forever)
						assert(false, "This needs to actually stop, somehow...");
						regs.pc -= 4; // HAX!

						// allow the debugger to break
//						machine.DebugBreak("STOP instruction reached", BR_HaltInstruction);
						break;
					case Instruction.MC68000_SUBXB:
					case Instruction.MC68000_SUBB:
					case Instruction.MC68000_SUBIB:
						int x = (op.op == Instruction.MC68000_SUBXB && (regs.sr & SF_Extend) ? 1 : 0);

						int result = cast(ubyte)operand1 - cast(ubyte)operand0 - x;
						if(op.am1 >= AddressingMode.Ind)
							Write8(address1, cast(ubyte)result);
						else
							regs.d[op.d1].b = cast(ubyte)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVnC(result, operand1, operand0, 8);
						break;
					case Instruction.MC68000_SUBXW:
					case Instruction.MC68000_SUBW:
					case Instruction.MC68000_SUBIW:
						int x = (op.op == Instruction.MC68000_SUBXW && (regs.sr & SF_Extend) ? 1 : 0);

						int result = cast(ushort)operand1 - cast(ushort)operand0 - x;
						if(op.am1 >= AddressingMode.Ind)
							Write16(address1, cast(ushort)result);
						else
							regs.d[op.d1].w = cast(ushort)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVnC(result, operand1, operand0, 16);
						break;
					case Instruction.MC68000_SUBXL:
					case Instruction.MC68000_SUBL:
					case Instruction.MC68000_SUBIL:
						int x = (op.op == Instruction.MC68000_SUBXL && (regs.sr & SF_Extend) ? 1 : 0);

						long result = cast(ulong)operand1 - cast(ulong)operand0 - x;
						if(op.am1 >= AddressingMode.Ind)
							Write32(address1, cast(uint)result);
						else
							regs.d[op.d1].l = cast(uint)result;

						regs.sr &= 0xFFE0;
						regs.sr |= FLAG_XNZVnC(result, operand1, operand0, 32);
						break;
					case Instruction.MC68000_SUBAW:
						regs.a[op.d1].l -= cast(short)cast(ushort)operand0;
						break;
					case Instruction.MC68000_SUBAL:
						regs.a[op.d1].l -= cast(int)operand0;
						break;
					case Instruction.MC68000_SWAP:
						regs.d[op.d0].l = ((regs.d[op.d0].l & 0xFFFF0000) >> 16) | ((regs.d[op.d0].l & 0xFFFF) << 16);
						regs.sr = (regs.sr & 0xFFF0) | FLAG_NZ(regs.d[op.d0].l, 32);
						break;
					case Instruction.MC68000_TAS:
						assert(false, "WRITE ME!");
						break;
					case Instruction.MC68000_TRAP:
						// raise a user exception
						RaiseException(ExceptionTable.TRAP0Vector + op.d0);
						break;
					case Instruction.MC68000_TRAPcc:
						// 68020+ instruction...
						assert(false, "WRITE ME!");
						break;
					case Instruction.MC68000_TRAPV:
						if(regs.sr & SF_Overflow)
						{
							// trapv exception
							RaiseException(ExceptionTable.TRAPVInstructionException);
						}
						break;
					case Instruction.MC68000_TSTB:
						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZ(operand0, 8);
						break;
					case Instruction.MC68000_TSTW:
						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZ(operand0, 16);
						break;
					case Instruction.MC68000_TSTL:
						regs.sr &= 0xFFF0;
						regs.sr |= FLAG_NZ(operand0, 32);
						break;
					case Instruction.MC68000_UNLK:
						regs.a[7].l = regs.a[op.d0].l;
						regs.a[op.d0].l = Pop32();
						break;
					case Instruction.MC68000_BKPT:
						// issue a breakpoint to the debugger
//						machine.DebugBreak("Breakpoint opcode reached", BR_Breakpoint);
						break;

						//
						// MC68010+ instructions
						//

					case Instruction.MC68010_RTD:
						assert(false, "WRITE ME!");
						break;
					case Instruction.MC68010_MOVEC:
						assert(false, "WRITE ME!");
						break;
					case Instruction.MC68010_MOVES:
						assert(false, "WRITE ME!");
						break;

						//
						// MC68020+ instructions
						//

					case Instruction.MC68020_UNPK:
						assert(false, "WRITE ME!");
						break;

					default:
						// invalid opcode!
						assert(false, "Unknown opcode!");
						break;
				}

				static if(EnableDissassembly)
				{
					if(bDisOpValid)
						WriteToLog(&disOp);
				}

				++opCount;
			}

			cycleCount += waitCycles;
			this.cycleCount = cycleCount;
			remainingCycles -= cast(int)(cycleCount - cc);
		}
		while(remainingCycles > 0 && !bYield);

		// return the number of cycles actually executed
		return numCycles - remainingCycles;
	}

	uint GetRegisterValue(int reg)
	{
		switch(reg)
		{
			case 0:
			case 1:
			case 2:
			case 3:
			case 4:
			case 5:
			case 6:
			case 7:
			case 8:
			case 9:
			case 10:
			case 11:
			case 12:
			case 13:
			case 14:
			case 15:
				return regs.d.ptr[reg].l;
			case 16:
				return regs.pc;
			case 17:
				return regs.usp;
			case 18:
				return regs.sr;
			case 19:
				return regs.sr & 0xFF;
			default:
				break;
		}
		return -1;
	}

	//==============================================================================
	// Set register
	//==============================================================================
	void SetRegisterValue(int reg, uint value)
	{
		switch(reg)
		{
			case 0:
			case 1:
			case 2:
			case 3:
			case 4:
			case 5:
			case 6:
			case 7:
			case 8:
			case 9:
			case 10:
			case 11:
			case 12:
			case 13:
			case 14:
			case 15:
				regs.d.ptr[reg].l = value;
				break;
			case 16: regs.pc = value;    break;
			case 17: regs.usp = value;   break;
			case 18: regs.sr = cast(ushort)value; break;
			case 19: regs.sr = (regs.sr & 0xFF00) | cast(ushort)(value & 0xFF); break;
			default:
				break;
		}
	}

	int DisassembleOpcode(uint address, DisassembledOp* pOpcode)
	{
		*pOpcode = DisassembledOp.init;
		pOpcode.programOffset = address & procInfo.addressMask;

		// read the opcode
		ushort opcode = Read16(address);
		address += 2;

		// decode the opcode
		Opcode op = void;
		bool bValidOp = Decode(opcode, op);
		if(!bValidOp)
			return 0;

		// add program code
		pOpcode.programCode[pOpcode.pcWords++] = opcode;

		// set opcode
		if(op.ds == DataSize.UNK)
			pOpcode.instructionName = pOpcodeNames[op.op];
		else
			pOpcode.instructionName.format("%s.%s", pOpcodeNames[op.op], gpSizeMnemonics[op.ds]);

		pOpcode.lineTemplate = "%s";

		// disassemble the args
		DisassembleArg(address, pOpcode, op.ds, op.am0, op.d0);
		DisassembleArg(address, pOpcode, op.ds, op.am1, op.d1);

		// add special sauce for some instructions
		switch(op.op)
		{
			case Instruction.MC68000_BTST:
			case Instruction.MC68000_BSET:
			case Instruction.MC68000_BCLR:
			case Instruction.MC68000_BCHG:
				pOpcode.instructionName = pOpcode.instructionName[0..$-2];
				break;
			case Instruction.MC68000_JMP:
				pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
			case Instruction.MC68000_JSR:
				// immediate targets should be flagged as JumpTarget for the disassembler to follow
				if(op.am0 == AddressingMode.AbsW || op.am0 == AddressingMode.AbsL)
					pOpcode.args[0].type = DisassembledOp.Arg.Type.JumpTarget;
				pOpcode.flags |= DisassembledOp.Flags.Jump;
				break;
			case Instruction.MC68000_RTS:
			case Instruction.MC68000_RTE:
			case Instruction.MC68000_RTR:
				pOpcode.flags |= DisassembledOp.Flags.Return | DisassembledOp.Flags.EndOfSequence;
				break;
			case Instruction.MC68000_BRA:
			case Instruction.MC68000_BSR:
			case Instruction.MC68000_BHI:
			case Instruction.MC68000_BLS:
			case Instruction.MC68000_BCC:
			case Instruction.MC68000_BCS:
			case Instruction.MC68000_BEQ:
			case Instruction.MC68000_BNE:
			case Instruction.MC68000_BVC:
			case Instruction.MC68000_BVS:
			case Instruction.MC68000_BPL:
			case Instruction.MC68000_BMI:
			case Instruction.MC68000_BGE:
			case Instruction.MC68000_BLT:
			case Instruction.MC68000_BGT:
			case Instruction.MC68000_BLE:
				switch(op.op)
				{
					case Instruction.MC68000_BRA:
						pOpcode.flags |= DisassembledOp.Flags.Jump | DisassembledOp.Flags.EndOfSequence;
						break;
					case Instruction.MC68000_BSR:
						pOpcode.flags |= DisassembledOp.Flags.Jump;
						break;
					default:
						pOpcode.flags |= DisassembledOp.Flags.Branch;
						break;
				}

				pOpcode.lineTemplate = "%s %s";

				DisassembledOp.Arg* arg = &pOpcode.args[0];
				arg.type = DisassembledOp.Arg.Type.JumpTarget;

				switch(op.am0)
				{
					case AddressingMode.Imm16:
						arg.value = address - 2 + cast(short)cast(ushort)arg.value;
						break;
					case AddressingMode.Imm:
						arg.value = address - 4 + arg.value;
						break;
					case AddressingMode.Provided:
						arg.value = address + cast(byte)cast(ubyte)arg.value;
						break;
					default:
						break;
				}

				arg.arg.format("$%0*X", procInfo.addressWidth >> 2, arg.value);
				break;
			case Instruction.MC68000_DBT:
			case Instruction.MC68000_DBF:
			case Instruction.MC68000_DBHI:
			case Instruction.MC68000_DBLS:
			case Instruction.MC68000_DBCC:
			case Instruction.MC68000_DBCS:
			case Instruction.MC68000_DBNE:
			case Instruction.MC68000_DBEQ:
			case Instruction.MC68000_DBVC:
			case Instruction.MC68000_DBVS:
			case Instruction.MC68000_DBPL:
			case Instruction.MC68000_DBMI:
			case Instruction.MC68000_DBGE:
			case Instruction.MC68000_DBLT:
			case Instruction.MC68000_DBGT:
			case Instruction.MC68000_DBLE:
				pOpcode.flags |= DisassembledOp.Flags.Branch;

				pOpcode.lineTemplate = "%s %s, %s";

				DisassembledOp.Arg* arg = &pOpcode.args[1];
				arg.type = DisassembledOp.Arg.Type.JumpTarget;

				switch(op.am0)
				{
					case AddressingMode.Imm16:
						address -= 2;
						break;
					case AddressingMode.Imm:
						address -= 4;
						break;
					default:
						break;
				}

				arg.value = address + cast(short)cast(ushort)arg.value;
				arg.arg.format("$%0*X", procInfo.addressWidth >> 2, arg.value);
				break;
			case Instruction.MC68000_MOVEM:
				// MOVEM is very unconventional...
				// Decode() will naturally produce the syntax: MOVEM #$REGS, <ea>
				// we need to produce the "REGS D0-3A1-2" string from the immediate and swap the args for loads
				if(opcode & 0x400)
				{
					// LOAD REGS SYNTAX: MOVEM <ea>, REGS

					// swap the args
					DisassembledOp.Arg t = pOpcode.args[1];
					pOpcode.args[1] = pOpcode.args[0];
					pOpcode.args[0] = t;

					// swap the second arg for the first arg, and remove the immediate decoration
					size_t comma = pOpcode.lineTemplate.rFind(',') + 1;
					char line[32];
					pOpcode.lineTemplate = sformat(line, "%%s%s, %%s", pOpcode.lineTemplate[comma..$]);
				}
				else
				{
					// STORE REGS SYNTAX: MOVEM REGS, <ea>

					// remove the immediate decoration from the first arg
					size_t comma = pOpcode.lineTemplate.rFind(',');
					char line[32];
					pOpcode.lineTemplate = sformat(line, "%%s %%s%s", pOpcode.lineTemplate[comma..$]);
				}

				DisassembledOp.Arg* pArg = &pOpcode.args[(opcode & 0x400) >> 10];
				ushort bits = cast(ushort)pArg.value;

				pArg.arg = "REGS ";

				int firstReg = -1, lastReg = -1;
				foreach(a; 0..16)
				{
					if(bits & (1 << a))
					{
						if(lastReg > -1)
						{
							if(a == lastReg + 1 && (a & 8) == (firstReg & 8))
								lastReg = a;
							else
							{
								// print range
								pArg.arg.formatAppend("-%d", lastReg & 7);
								lastReg = firstReg = -1;
							}
						}
						else
						{
							if(a == firstReg + 1)
								lastReg = a;
							else
								firstReg = -1;
						}

						if(firstReg == -1)
						{
							// print starting register
							pArg.arg ~= a < 8 ? 'D' : 'A';
							pArg.arg.formatAppend("%d", a & 7);
							firstReg = a;
						}
					}
				}

				// finalise the string
				if(lastReg)
					pArg.arg.formatAppend("-%d", lastReg & 7);
				break;
			case Instruction.MC68000_UNLK:
				op.d0 += 8;
			case Instruction.MC68000_SWAP:
				pOpcode.lineTemplate ~= " %s";

				DisassembledOp.Arg* arg = &pOpcode.args[pOpcode.numArgs++];
				arg.type = DisassembledOp.Arg.Type.Register;
				arg.arg = regInfo[op.d0].name;
				arg.value = op.d0;
				break;
			case Instruction.MC68000_TRAP:
				pOpcode.lineTemplate ~= " %s";
				DisassembledOp.Arg* arg = &pOpcode.args[pOpcode.numArgs++];
				arg.type = DisassembledOp.Arg.Type.Constant;
				arg.value = op.d0;
				arg.arg.format("#%d", op.d0);
				break;
			default:
				break;
		}

		return pOpcode.pcWords*2;
	}

private:
	// registers
	Registers regs;

	// chip features
	Version processorRevision;
	FPU_Model fpuModel;
	int fpuID; // coprocessor ID of the FPU if present

	ushort extensionWordMask;

	ExceptionTable exceptionPending;
	bool bUseAutoVectorInterrupts;

	const(InstructionTime)[] pInstructionCycleCounts;
	const(ubyte)[] pSpecialInstructionTimings;
	const(ubyte)[] pAddressModeCycleCounts;

	/+forceinline+/ void RaiseException(int vector)
	{
		exceptionPending = cast(ExceptionTable)vector;
	}

	void EnterSupervisorMode()
	{
		// set the supervisor flag
		regs.sr |= SF_Supervisor;
		// reset the trace bit
		regs.sr &= ~SF_T1;

		// swap the user stack pointer for the supervisor stack pointer
		uint ssp = regs.a[7].l;
		regs.a[7].l = regs.usp;
		regs.usp = ssp;
	}

	void ExitSupervisorMode()
	{
		// swap the supervisor stack pointer for the user stack pointer
		uint usp = regs.a[7].l;
		regs.a[7].l = regs.usp;
		regs.usp = usp;
	}

	/+forceinline+/ static int DecodeEA(ushort opcode, out AddressingMode am) pure nothrow
	{
		ushort d = g_ea[opcode & 0x3F].d;
		am = GET_AM(d);
		return GET_R(d);
	}

	bool Decode(ushort opcode, out Opcode op)
	{
		// the 68000 has a HORRIBLE instruction set to decode and a 16bit opcode table would just be WAAAAAY too big :(
		op.op = Instruction.MC68000_UNK;
		op.ds = DataSize.UNK;
		op.am0 = op.am1 = AddressingMode.UNK;

		// NOTE: the variables i0 and i1 control weather the argument resolution should fetch the value of indirect args from memory
		op.i0 = true; op.i1 = false;

		int selectBits = opcode >> 12;

		final switch(selectBits) // start with the top 4 bits
		{
			case 0x0:
				if(opcode & 0x100)
				{
					if((opcode & 0x38) == 0x08)
					{
						op.op = Instruction.MC68000_MOVEP;
						op.ds = cast(DataSize)(DataSize.Word + ((opcode >> 6 ) & 1));
						if(opcode & 0x80)
						{
							op.am0 = AddressingMode.DReg;
							op.d0 = (opcode >> 9) & 7;
							op.am1 = AddressingMode.IndOffset;
							op.d1 = opcode & 7;
						}
						else
						{
							op.am0 = AddressingMode.IndOffset;
							op.d0 = opcode & 7;
							op.i0 = false;
							op.am1 = AddressingMode.DReg;
							op.d1 = (opcode >> 9) & 7;
						}
					}
					else
					{
						// bit ops
						op.op = cast(Instruction)(Instruction.MC68000_BTST + ((opcode >> 6) & 0x3));
						op.ds = DataSize.Byte;
						op.am0 = AddressingMode.DReg;
						op.d0 = (opcode >> 9) & 7;
						op.d1 = DecodeEA(opcode, op.am1);
						op.i1 = true;
					}
				}
				else
				{
					// immediate arithmetic ops
					int inst = (opcode >> 9) & 0x7;
					final switch(inst)
					{
						case 0:
						case 1:
						case 5:
							// bitwise ops need to test for special register output
							if((opcode & 0x3F) == 0x3C)
								op.am1 = AddressingMode.StatusReg;
							else
							{
								case 2:
								case 3:
								case 6:
									// ATTENTION: we'll just abuse the switch syntax a little bit here by jumping into the else
									// arithmetic ops can't act on the status regs, so we just decode the target directly.
									op.d1 = DecodeEA(opcode, op.am1);
									op.i1 = true;
							}
							op.ds = cast(DataSize)((opcode >> 6) & 3);
							op.op = cast(Instruction)(Instruction.MC68000_ORB + inst + (op.ds << 3));
							op.am0 = AddressingMode.Imm;
							break;
						case 4:
							// bit ops
							op.op = cast(Instruction)(Instruction.MC68000_BTST + ((opcode >> 6) & 0x3));
							op.ds = DataSize.Byte;
							op.am0 = AddressingMode.Imm16;
							op.d1 = DecodeEA(opcode, op.am1);
							op.i1 = true;
							return true;
						case 7:
							// vacant?!
							break;
					}
				}
				break;
			case 0x1:
			case 0x3:
			case 0x2:
				op.ds = cast(DataSize)((selectBits ^ (selectBits >> 1)) - 1);

				ushort op1 = g_ea2[(opcode >> 6) & 0x3F].d;
				ushort op0 = g_ea[opcode & 0x3F].d;
				op.am1 = GET_AM(op1);
				op.d1 = GET_R(op1);
				op.am0 = GET_AM(op0);
				op.d0 = GET_R(op0);

				int movea = ((op.am1 - 2) >> 3) & (op.am1 << 1);
				op.op = cast(Instruction)(Instruction.MC68000_MOVEB + op.ds + movea);
				break;
			case 0x4:
				if((opcode & 0x100) == 0x100)
				{
					if((opcode & 0x40) == 0x40)
					{
						op.op = Instruction.MC68000_LEA;
						op.d0 = DecodeEA(opcode, op.am0);
						op.i0 = false;
						op.d1 = (opcode >> 9) & 7;
						op.am1 = AddressingMode.AReg;
					}
					else
					{
						op.op = Instruction.MC68000_CHK;
						op.ds = DataSize.Word;
						op.d0 = DecodeEA(opcode, op.am0);
						op.d1 = (opcode >> 9) & 0x7;
						op.am1 = AddressingMode.DReg;
					}
				}
				else
				{
					if(opcode & 0x800)
					{
						if((opcode & 0x380) == 0x80)
						{
							op.ds = cast(DataSize)(DataSize.Word + ((opcode >> 6) & 1));

							if((opcode & 0x38) == 0)
							{
								op.op = Instruction.MC68000_EXT;
								op.am0 = AddressingMode.DReg;
								op.d0 = opcode & 7;
							}
							else
							{
								op.op = Instruction.MC68000_MOVEM;
								op.am0 = AddressingMode.Imm16;
								op.d1 = DecodeEA(opcode, op.am1);
							}
						}
						else
						{
							if(opcode & 0x400)
							{
								if(opcode & 0x80)
								{
									if(opcode & 0x40)
									{
										op.op = Instruction.MC68000_JMP;
										op.d0 = DecodeEA(opcode, op.am0);
										op.i0 = false;
									}
									else
									{
										op.op = Instruction.MC68000_JSR;
										op.d0 = DecodeEA(opcode, op.am0);
										op.i0 = false;
									}
								}
								else
								{
									final switch((opcode >> 4) & 3)
									{
										case 0:
											op.op = Instruction.MC68000_TRAP;
											op.am0 = AddressingMode.Provided;
											op.d0 = opcode & 0xF;
											break;
										case 1:
											if(opcode & 0x8)
											{
												op.op = Instruction.MC68000_UNLK;
												op.am0 = AddressingMode.AReg;
												op.d0 = opcode & 0x7;
											}
											else
											{
												op.op = Instruction.MC68000_LINK;
												op.am0 = AddressingMode.AReg;
												op.d0 = opcode & 7;
												op.am1 = AddressingMode.Imm16;
											}
											break;
										case 2:
											op.op = Instruction.MC68000_MOVEUSP;
											if(opcode & 8)
											{
												op.am0 = AddressingMode.DReg;
												op.d0 = 17; // this is just so the disassembler shows the correct register, it us unused by the opcode
												op.am1 = AddressingMode.AReg;
												op.d1 = opcode & 7;
											}
											else
											{
												op.am0 = AddressingMode.AReg;
												op.d0 = opcode & 7;
												op.am1 = AddressingMode.DReg;
												op.d1 = 17; // this is just so the disassembler shows the correct register, it us unused by the opcode
											}
											break;
										case 3:
											op.op = cast(Instruction)(Instruction.MC68000_RESET + (opcode & 7));
											if(op.op == Instruction.MC68000_STOP)
												op.am0 = AddressingMode.Imm16;
											else if(op.op == Instruction.MC68000_TRAP)
												op.op = Instruction.MC68000_UNK;
											break;
									}
								}
							}
							else
							{
								if(opcode & 0x200)
								{
									if((opcode & 0xC0) == 0xC0)
									{
										if((opcode & 0x3F) == 0x3C)
										{
											op.op = Instruction.MC68000_ILLEGAL;
										}
										else
										{
											op.op = Instruction.MC68000_TAS;
											op.ds = DataSize.Byte;
											op.d0 = DecodeEA(opcode, op.am0);
										}
									}
									else
									{
										op.ds = cast(DataSize)((opcode >> 6) & 3);
										op.op = cast(Instruction)(Instruction.MC68000_TSTB + op.ds);
										op.d0 = DecodeEA(opcode, op.am0);
									}
								}
								else
								{
									if((opcode & 0x38) == 0)
									{
										op.op = Instruction.MC68000_SWAP;
										op.am0 = AddressingMode.DReg;
										op.d0 = opcode & 7;
									}
									else if((opcode & 0x40) == 0x40)
									{
										op.d0 = DecodeEA(opcode, op.am0);
										if(op.am0 >= AddressingMode.Ind)
										{
											op.op = Instruction.MC68000_PEA;
											op.i0 = false;
										}
									}
									else
									{
										op.op = Instruction.MC68000_NBCD;
										op.ds = DataSize.Byte;
										op.d0 = DecodeEA(opcode, op.am0);
									}
								}
							}
						}
					}
					else
					{
						if((opcode & 0xC0) == 0xC0)
						{
							int inst = (opcode >> 9) & 3;
							if(inst < 2)
							{
								// from SR
								op.op = cast(Instruction)(Instruction.MC68000_MOVESR - (inst & 1));
								op.ds = DataSize.Word;
								op.am0 = AddressingMode.StatusReg;
								op.d1 = DecodeEA(opcode, op.am1);
							}
							else
							{
								// to SR
								op.op = cast(Instruction)(Instruction.MC68000_MOVECCR + (inst & 1));
								op.ds = DataSize.Word;
								op.am1 = AddressingMode.StatusReg;
								op.d0 = DecodeEA(opcode, op.am0);
							}
						}
						else
						{
							// NEGX, CLR, NEG, NOT
							Instruction inst = cast(Instruction)(Instruction.MC68000_NEGXB + ((opcode >> 9) & 3));
							op.ds = cast(DataSize)((opcode >> 6) & 3);
							op.op = cast(Instruction)(inst + (op.ds << 2));
							op.d0 = DecodeEA(opcode, op.am0);
							if(inst == Instruction.MC68000_CLRB)
								op.i0 = false; // we don't need to fetch the operand to clear it
						}
					}
				}
				break;
			case 0x5:
				if((opcode & 0xC0) == 0xC0)
				{
					if((opcode & 0x38) == 0x8)
					{
						op.am0 = AddressingMode.DReg;
						op.d0 = opcode & 7;
						op.am1 = AddressingMode.Imm16;
						op.d1 = (opcode >> 8) & 0xF;
						op.op = cast(Instruction)(Instruction.MC68000_DBT + op.d1);
					}
					else
					{
						op.d0 = (opcode >> 8) & 0xF;
						op.d1 = DecodeEA(opcode, op.am1);
						op.op = cast(Instruction)(Instruction.MC68000_ST + op.d0);
					}
				}
				else
				{
					// ADDQ, SUBQ
					op.ds = cast(DataSize)((opcode >> 6) & 3);

					op.d1 = DecodeEA(opcode, op.am1);
					op.i1 = true;
					op.am0 = AddressingMode.Provided;
					op.d0 = (opcode >> 9) & 7;
					op.d0 |= (op.d0-1) & 8; // immediate value 0 == 8

					int movea = ((op.am1 - 2) >> 3) & (op.am1 << 1); // if we're targetting an AREG, add 2
					int sub = (opcode >> 5) & 8; // if we are doing a SUB opcode, add 8
					op.op = cast(Instruction)(Instruction.MC68000_ADDB + op.ds + sub + movea);
				}
				break;
			case 0x6:
				// branch opcodes
				op.op = cast(Instruction)(Instruction.MC68000_BRA + ((opcode >> 8) & 0xF));
				op.d0 = cast(byte)(opcode & 0xFF);
				if(op.d0 == 0)
					op.am0 = AddressingMode.Imm16;
				else if(processorRevision >= Version.MC68EC020 && cast(ubyte)op.d0 == 0xFF)
				{
					op.am0 = AddressingMode.Imm;
					op.ds = DataSize.Long;
				}
				else
					op.am0 = AddressingMode.Provided;
				break;
			case 0x7:
				op.op = Instruction.MC68000_MOVEQ;
				op.d0 = cast(byte)cast(ubyte)opcode;
				op.am0 = AddressingMode.Provided;
				op.d1 = (opcode >> 9) & 7;
				op.am1 = AddressingMode.DReg;
				break;
			case 0x8:
				if((opcode & 0xC0) == 0xC0)
				{
					if(opcode & 0x100)
						op.op = Instruction.MC68000_DIVS;
					else
						op.op = Instruction.MC68000_DIVU;
					op.ds = DataSize.Word;
					op.d0 = DecodeEA(opcode, op.am0);
					op.am1 = AddressingMode.DReg;
					op.d1 = (opcode >> 9) & 7;
				}
				else
				{
					if((opcode & 0x1F0) == 0x100)
					{
						op.op = Instruction.MC68000_SBCD;
						op.ds = DataSize.Byte;
						op.am0 = op.am1 = ((opcode >> 3) & 1) ? AddressingMode.IndPreDec : AddressingMode.DReg;
						op.d0 = opcode & 7;
						op.d1 = (opcode >> 9) & 7;
						op.i1 = true;
					}
					else
					{
						op.ds = cast(DataSize)((opcode >> 6) & 3);
						op.op = cast(Instruction)(Instruction.MC68000_ORB + (op.ds << 3));
						if(opcode & 0x100)
						{
							op.d0 = (opcode >> 9) & 7;
							op.am0 = AddressingMode.DReg;
							op.d1 = DecodeEA(opcode, op.am1);
							op.i1 = true;
						}
						else
						{
							op.d0 = DecodeEA(opcode, op.am0);
							op.d1 = (opcode >> 9) & 7;
							op.am1 = AddressingMode.DReg;
						}
					}
				}
				break;
			case 0x9:
				if((opcode & 0xC0) == 0xC0)
				{
					int subal = (opcode >> 8) & 1;
					op.ds = cast(DataSize)(DataSize.Word + subal);
					op.op = cast(Instruction)(Instruction.MC68000_SUBAW + subal);
					op.d0 = DecodeEA(opcode, op.am0);
					op.am1 = AddressingMode.AReg;
					op.d1 = (opcode >> 9) & 7;
				}
				else if((opcode & 130) == 0x100)
				{
					op.ds = cast(DataSize)((opcode >> 6) & 3);
					op.op = cast(Instruction)(Instruction.MC68000_SUBXB + op.ds);
					op.am0 = op.am1 = ((opcode >> 3) & 1) ? AddressingMode.IndPreDec : AddressingMode.DReg;
					op.d0 = opcode & 7;
					op.d1 = (opcode >> 9) & 7;
					op.i1 = true;
				}
				else
				{
					op.ds = cast(DataSize)((opcode >> 6) & 3);
					op.op = cast(Instruction)(Instruction.MC68000_SUBB + op.ds);
					if(opcode & 0x100)
					{
						op.d0 = (opcode >> 9) & 7;
						op.am0 = AddressingMode.DReg;
						op.d1 = DecodeEA(opcode, op.am1);
						op.i1 = true;
					}
					else
					{
						op.d0 = DecodeEA(opcode, op.am0);
						op.d1 = (opcode >> 9) & 7;
						op.am1 = AddressingMode.DReg;
					}
				}
				break;
			case 0xA:
				// vacant?!
				break;
			case 0xB:
				if((opcode & 0xC0) == 0xC0)
				{
					op.op = Instruction.MC68000_CMPA;
					op.ds = cast(DataSize)(DataSize.Word + ((opcode >> 8) & 1));
					op.d0 = DecodeEA(opcode, op.am0);
					op.am1 = AddressingMode.AReg;
					op.d1 = (opcode >> 9) & 7;
				}
				else if(opcode & 0x100)
				{
					if((opcode & 0x38) == 0x8)
					{
						op.op = Instruction.MC68000_CMPM;
						op.ds = cast(DataSize)((opcode >> 6) & 3);
						op.am0 = AddressingMode.IndPostInc;
						op.d0 = opcode & 7;
						op.am1 = AddressingMode.IndPostInc;
						op.d1 = (opcode >> 9) & 7;
						op.i1 = true;
					}
					else
					{
						op.ds = cast(DataSize)((opcode >> 6) & 3);
						op.op = cast(Instruction)(Instruction.MC68000_EORB + (op.ds << 3));
						op.am0 = AddressingMode.DReg;
						op.d0 = (opcode >> 9) & 7;
						op.d1 = DecodeEA(opcode, op.am1);
						op.i1 = true;
					}
				}
				else
				{
					op.ds = cast(DataSize)((opcode >> 6) & 3);
					op.op = cast(Instruction)(Instruction.MC68000_CMPB + (op.ds << 3));
					op.d0 = DecodeEA(opcode, op.am0);
					op.am1 = AddressingMode.DReg;
					op.d1 = (opcode >> 9) & 7;
				}
				break;
			case 0xC:
				if((opcode & 0xC0) == 0xC0)
				{
					if(opcode & 0x100)
						op.op = Instruction.MC68000_MULS;
					else
						op.op = Instruction.MC68000_MULU;
					op.ds = DataSize.Word;
					op.d0 = DecodeEA(opcode, op.am0);
					op.am1 = AddressingMode.DReg;
					op.d1 = (opcode >> 9) & 7;
				}
				else if((opcode & 0x130) == 0x100)
				{
					if((opcode & 0xC0) == 0x00)
					{
						op.op = Instruction.MC68000_ABCD;
						op.ds = DataSize.Byte;
						op.am0 = op.am1 = ((opcode >> 3) & 1) ? AddressingMode.IndPreDec : AddressingMode.DReg;
						op.d0 = opcode & 7;
						op.d1 = (opcode >> 9) & 7;
						op.i1 = true;
					}
					else
					{
						op.op = Instruction.MC68000_EXG;
						op.am0 = AddressingMode.DReg;
						op.d0 = ((opcode >> 9) & 7) + (((opcode >> 3) & opcode) & 0x8);
						op.am1 = AddressingMode.DReg;
						op.d1 = (opcode & 7) + (opcode & 0x8);
					}
				}
				else
				{
					op.ds = cast(DataSize)((opcode >> 6) & 3);
					op.op = cast(Instruction)(Instruction.MC68000_ANDB + (op.ds << 3));
					if(opcode & 0x100)
					{
						op.d0 = (opcode >> 9) & 7;
						op.am0 = AddressingMode.DReg;
						op.d1 = DecodeEA(opcode, op.am1);
						op.i1 = true;
					}
					else
					{
						op.d0 = DecodeEA(opcode, op.am0);
						op.d1 = (opcode >> 9) & 7;
						op.am1 = AddressingMode.DReg;
					}
				}
				break;
			case 0xD:
				if((opcode & 0xC0) == 0xC0)
				{
					int addal = (opcode >> 8) & 1;
					op.ds = cast(DataSize)(DataSize.Word + addal);
					op.op = cast(Instruction)(Instruction.MC68000_ADDAW + addal);
					op.d0 = DecodeEA(opcode, op.am0);
					op.am1 = AddressingMode.AReg;
					op.d1 = (opcode >> 9) & 7;
				}
				else if((opcode & 0x130) == 0x100)
				{
					op.ds = cast(DataSize)((opcode >> 6) & 3);
					op.op = cast(Instruction)(Instruction.MC68000_ADDXB + op.ds);
					op.am0 = op.am1 = ((opcode >> 3) & 1) ? AddressingMode.IndPreDec : AddressingMode.DReg;
					op.d0 = opcode & 7;
					op.d1 = (opcode >> 9) & 7;
					op.i1 = true;
				}
				else
				{
					op.ds = cast(DataSize)((opcode >> 6) & 3);
					op.op = cast(Instruction)(Instruction.MC68000_ADDB + op.ds);
					if(opcode & 0x100)
					{
						op.am0 = AddressingMode.DReg;
						op.d0 = (opcode >> 9) & 0x7;
						op.d1 = DecodeEA(opcode, op.am1);
						op.i1 = true;
					}
					else
					{
						op.d0 = DecodeEA(opcode, op.am0);
						op.am1 = AddressingMode.DReg;
						op.d1 = (opcode >> 9) & 0x7;
					}
				}
				break;
			case 0xE:
				// shifts and stuff
				// ASL/ASR, LSL/LSR, ROXL/ROXR, ROL/ROR
				ushort tmp_op = opcode;
				if((opcode & 0xC0) == 0xC0)
				{
					// memory source
					tmp_op >>= 9;
					op.ds = DataSize.Word;
					op.am0 = AddressingMode.Provided;
					op.d0 = 1;
					op.d1 = DecodeEA(opcode, op.am1);
					op.i1 = true;
				}
				else
				{
					// register source
					tmp_op >>= 3;
					op.d0 = (opcode >> 9) & 0x07;
					op.ds = cast(DataSize)((opcode >> 6) & 3);
					if (opcode & 0x20)
					{
						// shift count in register
						op.am0 = AddressingMode.DReg;
					}
					else
					{
						// shift count is in immediate position
						op.am0 = AddressingMode.Provided;
						op.d0 |= (op.d0 - 1) & 0x8;
					}
					op.am1 = AddressingMode.DReg;
					op.d1 = opcode & 0x07;
				}
				tmp_op &= 0x3;
				// adjust operand for shift/rotate direction
				tmp_op += (opcode & 0x0100) >> 6;
				// get instruction
				op.op = cast(Instruction)(Instruction.MC68000_ASRB + tmp_op + (op.ds << 3));
				break;
			case 0xF:
				// MMU/coprocessor interface
				int cpID = (opcode >> 9) & 7;

				if(cpID == fpuID)
				{
					// we have an FPU opcode
					//        ushort fpuOp = memmap.Read16_BE_Aligned(regs.pc & procInfo.addressMask);
					//        regs.pc += 2;

					// TODO: decode FPU opcode...
				}
				break;
		}

		return op.op == Instruction.MC68000_UNK ? false : true;
	}

	/+forceinline+/ uint CalculateIndexedEA(uint address)
	{
		// fetch the extension word
		ushort ext = Read16(regs.pc) & extensionWordMask;
		regs.pc += 2;

		// calculate the effective address
		if(ext & 0x100)
		{
			// calculate base address
			address = (ext & 0x80) ? 0 : address;

			// calculate base displacement
			if(ext & 0x20)
			{
				if(ext & 0x10)
				{
					address += Read32(regs.pc);
					regs.pc += 4;
				}
				else
				{
					address += cast(short)Read16(regs.pc);
					regs.pc += 2;
				}
			}

			// resolve post-index
			if(ext & 0x4)
				address = Read32(address);

			// load, sign extend, and scale the index register
			if(!(ext & 0x40))
			{
				int index = cast(int)regs.d[ext >> 12].l;
				if(!(ext & 0x800))
					index = cast(short)cast(ushort)index;
				index <<= (ext >> 9) & 3;
				address += index;
			}

			// resolve pre-index / indirect
			if(!(ext & 0x4) && (ext & 0x3))
				address = Read32(address);

			// calculate outer displacement
			if(ext & 0x2)
			{
				if(ext & 0x1)
				{
					address += Read32(regs.pc);
					regs.pc += 4;
				}
				else
				{
					address += cast(short)Read16(regs.pc);
					regs.pc += 2;
				}
			}
		}
		else
		{
			// calculate base offset
			address += cast(byte)cast(ubyte)ext;

			// sign extend the index register
			int index = cast(int)regs.d[ext >> 12].l;
			if(!(ext & 0x800))
				index = cast(short)cast(ushort)index;

			// scale the index register
			index <<= (ext >> 9) & 3;

			address += index;
		}

		return address;
	}

	void DisassembleArg(ref uint address, DisassembledOp* pOpcode, DataSize ds, AddressingMode am, int d)
	{
		// calculate the operand based on the addressing mode
		if(am != AddressingMode.UNK)
			pOpcode.lineTemplate.formatAppend("%s%s", pOpcode.numArgs > 0 ? "," : "", gpAddressModes[am]);

		switch(am)
		{
			case AddressingMode.AReg:
			case AddressingMode.Ind:
			case AddressingMode.IndPreDec:
			case AddressingMode.IndPostInc:
				d += 8;
			case AddressingMode.DReg:
				DisassembledOp.Arg* arg = &pOpcode.args[pOpcode.numArgs++];
				arg.type = DisassembledOp.Arg.Type.Register;
				arg.arg = regInfo[d].name;
				arg.value = d;
				break;
			case AddressingMode.IndOffset:
			case AddressingMode.OffsetPC:
				ushort offset = Read16(address);
				pOpcode.programCode[pOpcode.pcWords++] = offset;
				address += 2;

				DisassembledOp.Arg* off = &pOpcode.args[pOpcode.numArgs++];
				off.type = DisassembledOp.Arg.Type.Address;
				off.arg.format("$%X", offset);
				off.value = offset;

				// choose register
				if(am == AddressingMode.OffsetPC)
					d = 16;
				else
					d += 8;

				DisassembledOp.Arg* addr = &pOpcode.args[pOpcode.numArgs++];
				addr.type = DisassembledOp.Arg.Type.Register;
				addr.arg = regInfo[d].name;
				addr.value = d;
				break;
			case AddressingMode.IndIndex:
			case AddressingMode.IndexPC:
				// fetch the extension word
				ushort ext = Read16(address) & extensionWordMask;
				pOpcode.programCode[pOpcode.pcWords++] = ext;
				address += 2;

				if(ext & 0x100)
				{
					assert(false, "WRITE ME! (HEAVY DUTY 020 ADDRESSING MODE");
					/*
					// calculate base address
					address = (ext & 0x80) ? 0 : address;

					// calculate base displacement
					if(ext & 0x20)
					{
					if(ext & 0x10)
					{
					address += Read32(regs.pc);
					regs.pc += 4;
					}
					else
					{
					address += (short)Read16(regs.pc);
					regs.pc += 2;
					}
					}

					// resolve post-index
					if(ext & 0x4)
					address = Read32(address);

					// load, sign extend, and scale the index register
					if(!(ext & 0x40))
					{
					int index = (int)regs.d[ext >> 12];
					if(!(ext & 0x800))
					index = (short)(ushort)index;
					index <<= (ext >> 9) & 3;
					address += index;
					}

					// resolve pre-index / indirect
					if(!(ext & 0x4) && (ext & 0x3))
					address = Read32(address);

					// calculate outer displacement
					if(ext & 0x2)
					{
					if(ext & 0x1)
					{
					address += Read32(regs.pc);
					regs.pc += 4;
					}
					else
					{
					address += (short)Read16(regs.pc);
					regs.pc += 2;
					}
					}
					*/
				}
				else
				{
					// displacement
					DisassembledOp.Arg* off = &pOpcode.args[pOpcode.numArgs++];
					off.type = DisassembledOp.Arg.Type.Address;
					off.arg.format("$%X", ext & 0xFF);
					off.value = ext & 0xFF;

					// address (or PC) reg
					if(am == AddressingMode.OffsetPC)
						d = 16;
					else
						d += 8;

					DisassembledOp.Arg* addr = &pOpcode.args[pOpcode.numArgs++];
					addr.type = DisassembledOp.Arg.Type.Register;
					addr.arg = regInfo[d].name;
					addr.value = d;

					// index reg
					d = ext >> 12;
					DisassembledOp.Arg* idx = &pOpcode.args[pOpcode.numArgs++];
					idx.type = DisassembledOp.Arg.Type.Register;
					idx.arg = regInfo[d].name;
					idx.arg ~= (ext & 0x800) ? ".L" : ".W";
					idx.value = d;

					// scale
					if(ext & 0x600)
					{
						pOpcode.lineTemplate ~= "*%s";

						// add scale arg
						DisassembledOp.Arg* disp = &pOpcode.args[pOpcode.numArgs++];
						disp.type = DisassembledOp.Arg.Type.Constant;
						disp.value = 1 << ((ext >> 9) & 3);
						off.arg.format("%d", disp.value);
					}

					pOpcode.lineTemplate ~= ")";
				}
				break;
			case AddressingMode.AbsW:
				ushort addr = Read16(address);
				pOpcode.programCode[pOpcode.pcWords++] = addr;
				address += 2;

				DisassembledOp.Arg* arg = &pOpcode.args[pOpcode.numArgs++];
				arg.type = DisassembledOp.Arg.Type.Address;
				arg.value = cast(uint)cast(int)cast(short)addr & procInfo.addressMask;
				arg.arg.format("$%X", arg.value);
				break;
			case AddressingMode.AbsL:
				uint addr = Read32(address);
				pOpcode.programCode[pOpcode.pcWords++] = (addr >> 16);
				pOpcode.programCode[pOpcode.pcWords++] = addr & 0xFFFF;
				address += 4;

				DisassembledOp.Arg* arg = &pOpcode.args[pOpcode.numArgs++];
				arg.type = DisassembledOp.Arg.Type.Address;
				arg.value = addr & procInfo.addressMask;
				arg.arg.format("$%X", arg.value);
				break;
			case AddressingMode.Imm:
				uint operand;
				if(ds == DataSize.Long)
				{
					operand = Read32(address);
					pOpcode.programCode[pOpcode.pcWords++] = (operand >> 16);
					pOpcode.programCode[pOpcode.pcWords++] = operand & 0xFFFF;
					address += 4;
				}
				else
				{
					case AddressingMode.Imm16:
						operand = Read16(address);
						pOpcode.programCode[pOpcode.pcWords++] = operand;
						address += 2;
				}

				DisassembledOp.Arg* arg = &pOpcode.args[pOpcode.numArgs++];
				arg.type = DisassembledOp.Arg.Type.Immediate;
				arg.value = operand;
				arg.arg.format("#$%X", operand);
				break;
			case AddressingMode.StatusReg:
				int reg = ds == DataSize.Byte ? 19 : 18;

				DisassembledOp.Arg* arg = &pOpcode.args[pOpcode.numArgs++];
				arg.type = DisassembledOp.Arg.Type.Register;
				arg.arg = regInfo[reg].name;
				arg.value = reg;
				break;
			case AddressingMode.Provided:
				DisassembledOp.Arg* arg = &pOpcode.args[pOpcode.numArgs++];
				arg.type = DisassembledOp.Arg.Type.Immediate;
				arg.value = d;
				arg.arg.format("#$%X", d);
				break;
			default:
				break;
		}
	}

	// some handy inline functions
	/+forceinline+/ void Push16(ushort value)
	{
		regs.a[7].l -= 2;
		memmap.Write16_BE_Aligned(regs.a[7].l & procInfo.addressMask, value);
	}
	/+forceinline+/ void Push32(uint value)
	{
		regs.a[7].l -= 4;
		memmap.Write32_BE_Aligned_16(regs.a[7].l & procInfo.addressMask, value);
	}
	/+forceinline+/ ushort Pop16()
	{
		ushort value = memmap.Read16_BE_Aligned(regs.a[7].l & procInfo.addressMask);
		regs.a[7].l += 2;
		return value;
	}
	/+forceinline+/ uint Pop32()
	{
		uint value = memmap.Read32_BE_Aligned_16(regs.a[7].l & procInfo.addressMask);
		regs.a[7].l += 4;
		return value;
	}

	// some inlines wrapping logic to perform alignment exception handling
	/+forceinline+/ ubyte Read8(uint address)
	{
		return memmap.Read8(address & procInfo.addressMask);
	}
	/+forceinline+/ void Write8(uint address, ubyte value)
	{
		memmap.Write8(address & procInfo.addressMask, value);
	}
	/+forceinline+/ ushort Read16(uint address)
	{
		if(address & 1)
		{
			RaiseException(ExceptionTable.AlignmentException); // raise alignment exception
			return 0xFFFF;
		}

		return memmap.Read16_BE_Aligned(address & procInfo.addressMask);
	}
	/+forceinline+/ void Write16(uint address, ushort value)
	{
		if(address & 1)
			RaiseException(ExceptionTable.AlignmentException); // raise alignment exception
		else
			memmap.Write16_BE_Aligned(address & procInfo.addressMask, value);
	}
	/+forceinline+/ uint Read32(uint address)
	{
		if(address & 1)
		{
			RaiseException(ExceptionTable.AlignmentException); // raise alignment exception
			return 0xFFFFFFFF;
		}

		return memmap.Read32_BE_Aligned_16(address & procInfo.addressMask);
	}
	/+forceinline+/ void Write32(uint address, uint value)
	{
		if(address & 1)
			RaiseException(ExceptionTable.AlignmentException); // raise alignment exception
		else
			memmap.Write32_BE_Aligned_16(address & procInfo.addressMask, value);
	}
}

private:

alias ubyte[4] InstructionTime;

// status flags register
enum : ushort
{
	SF_Carry                 = 0x01,
	SF_Overflow              = 0x02,
	SF_Zero                  = 0x04,
	SF_Negative              = 0x08,
	SF_Extend                = 0x10,

	SF_InterruptLevelMask    = 0x700,

	SF_MasterInterruptSwitch = 0x1000,
	SF_Supervisor            = 0x2000,
	SF_T0                    = 0x4000,
	SF_T1                    = 0x8000
}

// opcode data
struct Opcode
{
	Instruction op;
	AddressingMode am0, am1;
	DataSize ds;
	int d0, d1;
	bool i0, i1;
}

// cpu registers
struct Registers
{
	union Register
	{
		uint l;
		version(BigEndian)
		{
			struct { ushort paddw, w; }
			struct { ubyte[3] paddb, b; }
		}
		else
		{
			ushort w;
			ubyte b;
		}
	}

	Register d[8];
	Register a[8];
	uint usp;   // user stack pointer
	uint isp;   // interrupt stack pointer
	uint msp;   // master stack pointer
	uint pc;    // program counter
	ushort sr;  // status register
}


enum Instruction
{
	MC68000_UNK = cast(ubyte)-1, // unknown opcode

	// 68000 instructions

	// these need to stay in sequence!
	MC68000_ORB = 0,
	MC68000_ANDB,
	MC68000_SUBIB,
	MC68000_ADDIB,
	MC68000_ABCD, // this can move
	MC68000_EORB,
	MC68000_CMPB,
	MC68000_SBCD, // this can move
	MC68000_ORW,
	MC68000_ANDW,
	MC68000_SUBIW,
	MC68000_ADDIW,
	MC68000_MOVEP, // this can move
	MC68000_EORW,
	MC68000_CMPW,
	MC68000_MOVEM, // this can move
	MC68000_ORL,
	MC68000_ANDL,
	MC68000_SUBIL,
	MC68000_ADDIL,
	MC68000_LINK, // this can move
	MC68000_EORL,
	MC68000_CMPL,
	MC68000_UNLK, // this can move

	// these need to stay in sequence
	MC68000_BTST,
	MC68000_BCHG,
	MC68000_BCLR,
	MC68000_BSET,

	// these need to stay in sequence
	MC68000_NEGXB,
	MC68000_CLRB,
	MC68000_NEGB,
	MC68000_NOTB,
	MC68000_NEGXW,
	MC68000_CLRW,
	MC68000_NEGW,
	MC68000_NOTW,
	MC68000_NEGXL,
	MC68000_CLRL,
	MC68000_NEGL,
	MC68000_NOTL,

	// these need to stay in sequence
	MC68000_RESET,
	MC68000_NOP,
	MC68000_STOP,
	MC68000_RTE,
	MC68000_TRAP, // this can move
	MC68000_RTS,
	MC68000_TRAPV,
	MC68000_RTR,

	// these need to stay in order
	MC68000_ASRB,
	MC68000_LSRB,
	MC68000_ROXRB,
	MC68000_RORB,
	MC68000_ASLB,
	MC68000_LSLB,
	MC68000_ROXLB,
	MC68000_ROLB,
	MC68000_ASRW,
	MC68000_LSRW,
	MC68000_ROXRW,
	MC68000_RORW,
	MC68000_ASLW,
	MC68000_LSLW,
	MC68000_ROXLW,
	MC68000_ROLW,
	MC68000_ASRL,
	MC68000_LSRL,
	MC68000_ROXRL,
	MC68000_RORL,
	MC68000_ASLL,
	MC68000_LSLL,
	MC68000_ROXLL,
	MC68000_ROLL,

	// these need to stay in order
	MC68000_MOVEB,
	MC68000_MOVEW,
	MC68000_MOVEL,
	MC68000_MOVEAW,
	MC68000_MOVEAL,

	// these need to stay in order
	MC68000_ADDB,
	MC68000_ADDW,
	MC68000_ADDL,
	MC68000_ADDAW,
	MC68000_ADDAL,
	MC68000_ADDXB,
	MC68000_ADDXW,
	MC68000_ADDXL,
	MC68000_SUBB,
	MC68000_SUBW,
	MC68000_SUBL,
	MC68000_SUBAW,
	MC68000_SUBAL,
	MC68000_SUBXB,
	MC68000_SUBXW,
	MC68000_SUBXL,

	// branch opcodes need to stay in order
	//  MC68000_Bcc
	MC68000_BRA,
	MC68000_BSR,
	MC68000_BHI,
	MC68000_BLS,
	MC68000_BCC,
	MC68000_BCS,
	MC68000_BNE,
	MC68000_BEQ,
	MC68000_BVC,
	MC68000_BVS,
	MC68000_BPL,
	MC68000_BMI,
	MC68000_BGE,
	MC68000_BLT,
	MC68000_BGT,
	MC68000_BLE,

	//  MC68000_DBcc
	MC68000_DBT,
	MC68000_DBF,
	MC68000_DBHI,
	MC68000_DBLS,
	MC68000_DBCC,
	MC68000_DBCS,
	MC68000_DBNE,
	MC68000_DBEQ,
	MC68000_DBVC,
	MC68000_DBVS,
	MC68000_DBPL,
	MC68000_DBMI,
	MC68000_DBGE,
	MC68000_DBLT,
	MC68000_DBGT,
	MC68000_DBLE,

	//  MC68000_Scc
	MC68000_ST,
	MC68000_SF,
	MC68000_SHI,
	MC68000_SLS,
	MC68000_SCC,
	MC68000_SCS,
	MC68000_SNE,
	MC68000_SEQ,
	MC68000_SVC,
	MC68000_SVS,
	MC68000_SPL,
	MC68000_SMI,
	MC68000_SGE,
	MC68000_SLT,
	MC68000_SGT,
	MC68000_SLE,

	// from here on are good to be rearranged
	MC68000_MOVEQ,
	MC68000_MOVECCR,
	MC68000_MOVESR,
	MC68000_MOVEUSP,
	MC68000_CHK,
	MC68000_CMPA,
	MC68000_CMPM,
	MC68000_DIVS,
	MC68000_DIVU,
	MC68000_EXG,
	MC68000_EXT,
	MC68000_ILLEGAL,
	MC68000_JMP,
	MC68000_JSR,
	MC68000_LEA,
	MC68000_MULS,
	MC68000_MULU,
	MC68000_NBCD,
	MC68000_PEA,
	MC68000_SWAP,
	MC68000_TAS,
	MC68000_TRAPcc,
	MC68000_TSTB,
	MC68000_TSTW,
	MC68000_TSTL,
	MC68000_BKPT,

	// 68010 instructions
	MC68010_RTD,    // Return and Deallocate
	MC68010_MOVEC,  // Move Address Space
	MC68010_MOVES,  // Move Control Register

	// 68020 instructions
	MC68020_UNPK,

	// 68040 instructions
	//...

	// 68060 instructions
	//...

	// 68881 instructions
	//...

	// 68882 instructions
	//...

	Max
}

enum AddressingMode
{
	// basic addressing modes
	DReg = 0,
	AReg,
	Ind,
	IndPostInc,
	IndPreDec,
	IndOffset,
	IndIndex,
	Special,

	// special address modes
	AbsW,
	AbsL,
	OffsetPC,
	IndexPC,
	Imm,

	// additional addressing modes
	Imm16,
	StatusReg,
	Provided,
	Implicit,

	UNK, // unknown opcode

	Max
}

enum DataSize
{
	UNK = -1,

	Byte = 0,
	Word,
	Long,
	Quad,

	Max
}

enum Conditions
{
	Unknown = -1,

	True = 0,
	False,
	High,
	LowOrSame,
	CarryClear,
	CarrySet,
	NotEqual,
	Equal,
	OverflowClear,
	OverflowSet,
	Plus,
	Minus,
	GreaterOrEqual,
	LessThan,
	GreaterThan,
	LessOrEqual,

	Max
}

enum FPU_Model
{
	None = 0,
	MC68881,
	MC68882,
	MC68040,
	MC68060
}

enum ExceptionTable
{
	UnknownException = -1,
	NoException = 0,

	ResetStackPointer = 0,
	ResetProgramCounter,
	BusErrorException,
	AlignmentException,
	IllegalInstructionException,
	DivideByZeroException,
	CHKInstructionException,
	TRAPVInstructionException,
	PrivilegeViolationException,
	TraceException,
	Line1010EmulatorException,
	Line1111EmulatorException,

	CoprocessorProtocolViolationException = 13,
	FormatErrorException,
	UninitializedInterruptException,

	SpuriousInterruptException = 24,
	Int1Autovector,
	Int2Autovector,
	Int3Autovector,
	Int4Autovector,
	Int5Autovector,
	Int6Autovector,
	Int7Autovector,
	TRAP0Vector,
	TRAP1Vector,
	TRAP2Vector,
	TRAP3Vector,
	TRAP4Vector,
	TRAP5Vector,
	TRAP6Vector,
	TRAP7Vector,
	TRAP8Vector,
	TRAP9Vector,
	TRAP10Vector,
	TRAP11Vector,
	TRAP12Vector,
	TRAP13Vector,
	TRAP14Vector,
	TRAP15Vector,
	FPBranchSetUnorderedException,
	FPInexactResultException,
	FPDivideByZeroException,
	FPUnderflowException,
	FPOperandErrorException,
	FPOverflowException,
	FPSignalingNANException,
	FPUnimplementedDataTypeException,
	MMUConfigurationErrorException,
	MMUIllegalOperationErrorException,
	MMUAddessLevelViolationErrorException,

	UserVectors = 64,
	UserVector0 = UserVectors
}

enum SpecialInstructionTimings
{
	MOVEM_Load,
	MOVEM_Store,

	MOVESR_SR2Reg,
	MOVESR_SR2Mem,
	MOVESR_ToSR,

	MOVEUSP_USP2Reg,
	MOVEUSP_Reg2USP,

	Bcc_Taken,
	Bcc_B_NotTaken,
	Bcc_W_NotTaken,
	Bcc_L_NotTaken,

	DBcc_ccTrue,
	DBcc_ccFalse_Expired,
	DBcc_ccFalse_NotExpired,

	Scc_ccTrue_Reg,
	Scc_ccTrue_Mem,
	Scc_ccFalse_Reg,
	Scc_ccFalse_Mem,

	Max
}

// define a pile of macros for setting CPU flags
// *** TRY: (v | -v) >> 8 & 1 // FOR THE ZERO TEST!!
ushort FLAG_Z(T)(T result, int bits) pure nothrow								{ return cast(ushort)((result & cast(uint)((1 << bits)-1)) ? 0 : SF_Zero); }
ushort FLAG_N(T)(T result, int bits) pure nothrow								{ return cast(ushort)((result >> (bits-4)) & SF_Negative); }
ushort FLAG_C(T)(T result, int bits) pure nothrow								{ return cast(ushort)((result >> bits) & SF_Carry); }
ushort FLAG_X(T)(T result, int bits) pure nothrow								{ return cast(ushort)((result >> (bits-4)) & SF_Extend); }
ushort FLAG_V(T, O)(T result, O operand0, O operand1, int bits) pure nothrow	{ return cast(ushort)(((~(operand0^operand1) & (operand0^cast(uint)result)) >> (bits-2)) & SF_Overflow); }
ushort FLAG_Vn(T, O)(T result, O operand0, O operand1, int bits) pure nothrow	{ return cast(ushort)((((operand0^operand1) & (operand0^cast(uint)result)) >> (bits-2)) & SF_Overflow); }

// we'll define useful combinations of flags
ushort FLAG_NZ(T)(T result, int bits) pure nothrow									{ return (FLAG_N(result, bits) | FLAG_Z(result, bits)); }
ushort FLAG_NZC(T)(T result, int bits) pure nothrow									{ return (FLAG_N(result, bits) | FLAG_Z(result, bits) | FLAG_C(result, bits)); }
ushort FLAG_XNZC(T)(T result, int bits) pure nothrow								{ return (FLAG_X(result, bits) | FLAG_N(result, bits) | FLAG_Z(result, bits) | FLAG_C(result, bits)); }
ushort FLAG_NZVC(T, O)(T result, O operand0, O operand1, int bits) pure nothrow		{ return (FLAG_N(result, bits) | FLAG_Z(result, bits) | FLAG_V(result, operand0, operand1, bits) | FLAG_C(result, bits)); }
ushort FLAG_NZVnC(T, O)(T result, O operand0, O operand1, int bits) pure nothrow	{ return (FLAG_N(result, bits) | FLAG_Z(result, bits) | FLAG_Vn(result, operand0, operand1, bits) | FLAG_C(result, bits)); }
ushort FLAG_XNZVC(T, O)(T result, O operand0, O operand1, int bits) pure nothrow	{ return (FLAG_X(result, bits) | FLAG_N(result, bits) | FLAG_Z(result, bits) | FLAG_V(result, operand0, operand1, bits) | FLAG_C(result, bits)); }
ushort FLAG_XNZVnC(T, O)(T result, O operand0, O operand1, int bits) pure nothrow	{ return (FLAG_X(result, bits) | FLAG_N(result, bits) | FLAG_Z(result, bits) | FLAG_Vn(result, operand0, operand1, bits) | FLAG_C(result, bits)); }

// other helpful macros
ushort INT_ABS16(ushort i) pure nothrow
{
	return cast(ushort)(((i >>> 15u) ^ i) + (i >> 15u));
}
uint INT_ABS32(uint i) pure nothrow
{
	return ((i >>> 31u) ^ i) + (i >> 31u);
}

struct MC68kVersionInfo
{
	string name;
	int addressWidth, dataWidth;
	uint addressMask, dataMask;
	uint wordAlign;
}

struct EffectiveAddressTable
{
	union
	{
		struct
		{
			ubyte am;
			ubyte r;
		}
		ushort d;
	}
}

static immutable EffectiveAddressTable[64] g_ea =
[
	EffectiveAddressTable( AddressingMode.DReg, 0 ),
	EffectiveAddressTable( AddressingMode.DReg, 1 ),
	EffectiveAddressTable( AddressingMode.DReg, 2 ),
	EffectiveAddressTable( AddressingMode.DReg, 3 ),
	EffectiveAddressTable( AddressingMode.DReg, 4 ),
	EffectiveAddressTable( AddressingMode.DReg, 5 ),
	EffectiveAddressTable( AddressingMode.DReg, 6 ),
	EffectiveAddressTable( AddressingMode.DReg, 7 ),
	EffectiveAddressTable( AddressingMode.AReg, 0 ),
	EffectiveAddressTable( AddressingMode.AReg, 1 ),
	EffectiveAddressTable( AddressingMode.AReg, 2 ),
	EffectiveAddressTable( AddressingMode.AReg, 3 ),
	EffectiveAddressTable( AddressingMode.AReg, 4 ),
	EffectiveAddressTable( AddressingMode.AReg, 5 ),
	EffectiveAddressTable( AddressingMode.AReg, 6 ),
	EffectiveAddressTable( AddressingMode.AReg, 7 ),
	EffectiveAddressTable( AddressingMode.Ind, 0 ),
	EffectiveAddressTable( AddressingMode.Ind, 1 ),
	EffectiveAddressTable( AddressingMode.Ind, 2 ),
	EffectiveAddressTable( AddressingMode.Ind, 3 ),
	EffectiveAddressTable( AddressingMode.Ind, 4 ),
	EffectiveAddressTable( AddressingMode.Ind, 5 ),
	EffectiveAddressTable( AddressingMode.Ind, 6 ),
	EffectiveAddressTable( AddressingMode.Ind, 7 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 0 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 1 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 2 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 3 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 4 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 5 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 6 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 7 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 0 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 1 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 2 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 3 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 4 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 5 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 6 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 7 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 0 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 1 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 2 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 3 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 4 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 5 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 6 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 7 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 0 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 1 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 2 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 3 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 4 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 5 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 6 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 7 ),
	EffectiveAddressTable( AddressingMode.AbsW, 0 ),
	EffectiveAddressTable( AddressingMode.AbsL, 0 ),
	EffectiveAddressTable( AddressingMode.OffsetPC, 0 ),
	EffectiveAddressTable( AddressingMode.IndexPC, 0 ),
	EffectiveAddressTable( AddressingMode.Imm, 0 ),
	EffectiveAddressTable( AddressingMode.UNK, 0 ),
	EffectiveAddressTable( AddressingMode.UNK, 0 ),
	EffectiveAddressTable( AddressingMode.UNK, 0 )
];


static immutable EffectiveAddressTable[64] g_ea2 =
[
	EffectiveAddressTable( AddressingMode.DReg, 0 ),
	EffectiveAddressTable( AddressingMode.AReg, 0 ),
	EffectiveAddressTable( AddressingMode.Ind, 0 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 0 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 0 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 0 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 0 ),
	EffectiveAddressTable( AddressingMode.AbsW, 0 ),
	EffectiveAddressTable( AddressingMode.DReg, 1 ),
	EffectiveAddressTable( AddressingMode.AReg, 1 ),
	EffectiveAddressTable( AddressingMode.Ind, 1 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 1 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 1 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 1 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 1 ),
	EffectiveAddressTable( AddressingMode.AbsL, 0 ),
	EffectiveAddressTable( AddressingMode.DReg, 2 ),
	EffectiveAddressTable( AddressingMode.AReg, 2 ),
	EffectiveAddressTable( AddressingMode.Ind, 2 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 2 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 2 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 2 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 2 ),
	EffectiveAddressTable( AddressingMode.OffsetPC, 0 ),
	EffectiveAddressTable( AddressingMode.DReg, 3 ),
	EffectiveAddressTable( AddressingMode.AReg, 3 ),
	EffectiveAddressTable( AddressingMode.Ind, 3 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 3 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 3 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 3 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 3 ),
	EffectiveAddressTable( AddressingMode.IndexPC, 0 ),
	EffectiveAddressTable( AddressingMode.DReg, 4 ),
	EffectiveAddressTable( AddressingMode.AReg, 4 ),
	EffectiveAddressTable( AddressingMode.Ind, 4 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 4 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 4 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 4 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 4 ),
	EffectiveAddressTable( AddressingMode.Imm, 0 ),
	EffectiveAddressTable( AddressingMode.DReg, 5 ),
	EffectiveAddressTable( AddressingMode.AReg, 5 ),
	EffectiveAddressTable( AddressingMode.Ind, 5 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 5 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 5 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 5 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 5 ),
	EffectiveAddressTable( AddressingMode.UNK, 0 ),
	EffectiveAddressTable( AddressingMode.DReg, 6 ),
	EffectiveAddressTable( AddressingMode.AReg, 6 ),
	EffectiveAddressTable( AddressingMode.Ind, 6 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 6 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 6 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 6 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 6 ),
	EffectiveAddressTable( AddressingMode.UNK, 0 ),
	EffectiveAddressTable( AddressingMode.DReg, 7 ),
	EffectiveAddressTable( AddressingMode.AReg, 7 ),
	EffectiveAddressTable( AddressingMode.Ind, 7 ),
	EffectiveAddressTable( AddressingMode.IndPostInc, 7 ),
	EffectiveAddressTable( AddressingMode.IndPreDec, 7 ),
	EffectiveAddressTable( AddressingMode.IndOffset, 7 ),
	EffectiveAddressTable( AddressingMode.IndIndex, 7 ),
	EffectiveAddressTable( AddressingMode.UNK, 0 )
];

version(BigEndian)
{
	AddressingMode GET_AM()(ushort value) { return cast(AddressingMode)cast(byte)(value >> 8); }
	int GET_R()(ushort value) { return value & 0xFF; }
}
else
{
	AddressingMode GET_AM()(ushort value) { return cast(AddressingMode)cast(byte)(value & 0xFF); }
	int GET_R()(ushort value) { return value >> 8; }
}

static string[Instruction.Max] pOpcodeNames =
[
	"OR",
	"AND",
	"SUB",
	"ADD",
	"ABCD",
	"EOR",
	"CMP",
	"SBCD",
	"OR",
	"AND",
	"SUB",
	"ADD",
	"MOVEP",
	"EOR",
	"CMP",
	"MOVEM",
	"OR",
	"AND",
	"SUB",
	"ADD",
	"LINK",
	"EOR",
	"CMP",
	"UNLK",

	"BTST",
	"BCHG",
	"BCLR",
	"BSET",

	"NEGX",
	"CLR",
	"NEG",
	"NOT",
	"NEGX",
	"CLR",
	"NEG",
	"NOT",
	"NEGX",
	"CLR",
	"NEG",
	"NOT",

	"RESET",
	"NOP",
	"STOP",
	"RTE",
	"TRAP",
	"RTS",
	"TRAPV",
	"RTR",

	"ASR",
	"LSR",
	"ROXR",
	"ROR",
	"ASL",
	"LSL",
	"ROXL",
	"ROL",
	"ASR",
	"LSR",
	"ROXR",
	"ROR",
	"ASL",
	"LSL",
	"ROXL",
	"ROL",
	"ASR",
	"LSR",
	"ROXR",
	"ROR",
	"ASL",
	"LSL",
	"ROXL",
	"ROL",

	"MOVE",
	"MOVE",
	"MOVE",
	"MOVEA",
	"MOVEA",

	"ADD",
	"ADD",
	"ADD",
	"ADDA",
	"ADDA",
	"ADDX",
	"ADDX",
	"ADDX",
	"SUB",
	"SUB",
	"SUB",
	"SUBA",
	"SUBA",
	"SUBX",
	"SUBX",
	"SUBX",

	"BRA",
	"BSR",
	"BHI",
	"BLS",
	"BCC",
	"BCS",
	"BNE",
	"BEQ",
	"BVC",
	"BVS",
	"BPL",
	"BMI",
	"BGE",
	"BLT",
	"BGT",
	"BLE",

	"DBT",
	"DBF",
	"DBHI",
	"DBLS",
	"DBCC",
	"DBCS",
	"DBNE",
	"DBEQ",
	"DBVC",
	"DBVS",
	"DBPL",
	"DBMI",
	"DBGE",
	"DBLT",
	"DBGT",
	"DBLE",

	"ST",
	"SF",
	"SHI",
	"SLS",
	"SCC",
	"SCS",
	"SNE",
	"SEQ",
	"SVC",
	"SVS",
	"SPL",
	"SMI",
	"SGE",
	"SLT",
	"SGT",
	"SLE",

	"MOVEQ",
	"MOVE",
	"MOVE",
	"MOVE",
	"CHK",
	"CMPA",
	"CMPM",
	"DIVS",
	"DIVU",
	"EXG",
	"EXT",
	"ILLEGAL",
	"JMP",
	"JSR",
	"LEA",
	"MULS",
	"MULU",
	"NBCD",
	"PEA",
	"SWAP",
	"TAS",
	"TRAPcc",
	"TST",
	"TST",
	"TST",
	"BKPT",

	"RTD",
	"MOVEC",
	"MOVES",
	"UNPK"
];

static immutable RegisterInfo[] sRegInfo =
[
	RegisterInfo( "D0", 32, 0, null ),
	RegisterInfo( "D1", 32, 0, null ),
	RegisterInfo( "D2", 32, 0, null ),
	RegisterInfo( "D3", 32, 0, null ),
	RegisterInfo( "D4", 32, 0, null ),
	RegisterInfo( "D5", 32, 0, null ),
	RegisterInfo( "D6", 32, 0, null ),
	RegisterInfo( "D7", 32, 0, null ),
	RegisterInfo( "A0", 32, 0, null ),
	RegisterInfo( "A1", 32, 0, null ),
	RegisterInfo( "A2", 32, 0, null ),
	RegisterInfo( "A3", 32, 0, null ),
	RegisterInfo( "A4", 32, 0, null ),
	RegisterInfo( "A5", 32, 0, null ),
	RegisterInfo( "A6", 32, 0, null ),
	RegisterInfo( "SP", 32, RegisterInfo.Flags.StackPointer, null ),
	RegisterInfo( "PC", 32, RegisterInfo.Flags.ProgramCounter, null ),
	RegisterInfo( "USP", 32, 0, null ),
	RegisterInfo( "SR", 16, RegisterInfo.Flags.FlagsRegister, "TFSM.210...XNZVC" ),
	RegisterInfo( "CCR", 8, RegisterInfo.Flags.FlagsRegister, "...XNZVC" )
];

immutable int[] sDisplayRegs = [ 8, 9, 10, 11, 12, 13, 14, 15, 17, 16, -2, 0, 1, 2, 3, 4, 5, 6, 7, 18 ];
immutable int[] sDisplayRegsOnOneLine = [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 16, 18 ];

static immutable MC68kVersionInfo[MC68000.Version.Max] g68kVersionInfo =
[
	MC68kVersionInfo( "MC68000",   24, 16, 0xFFFFFF,   0xFFFF,     0xFFFFFFFE ),
	MC68kVersionInfo( "MC68008",   20, 8,  0xFFFFF,    0xFF,       0xFFFFFFFE ),
	MC68kVersionInfo( "MC68010",   24, 16, 0xFFFFFF,   0xFFFF,     0xFFFFFFFE ),
	MC68kVersionInfo( "MC68012",   31, 16, 0x7FFFFFFF, 0xFFFF,     0xFFFFFFFE ),
	MC68kVersionInfo( "MC68EC020", 24, 32, 0xFFFFFF,   0xFFFFFFFF, 0xFFFFFFFF ),
	MC68kVersionInfo( "MC68020",   32, 32, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF ),
	MC68kVersionInfo( "MC68030",   32, 32, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF ),
	MC68kVersionInfo( "MC68040",   32, 32, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF ),
	MC68kVersionInfo( "MC68060",   32, 32, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF ),
];

static immutable int[DataSize.Max] gDSBytes = [ 1, 2, 4, 8 ];
static immutable uint[DataSize.Quad] gDSMask = [ 0xFF, 0xFFFF, 0xFFFFFFFF ];

static immutable ubyte[AddressingMode.Max] addressModeCycleCounts_68000 = 
[
	0, // AddressingMode.DReg = 0
	0, // AddressingMode.AReg
	0, // AddressingMode.Ind
	0, // AddressingMode.IndPostInc
	0,//2, // AddressingMode.IndPreDec
	2,//4, // AddressingMode.IndOffset
	2,//6, // AddressingMode.IndIndex
	0, // AddressingMode.Special
	2,//4, // AddressingMode.AbsW
	4,//8, // AddressingMode.AbsL
	2,//4, // AddressingMode.OffsetPC
	2,//6, // AddressingMode.IndexPC
	0, // AddressingMode.Imm
	0, // AddressingMode.Imm16
	12,// AddressingMode.StatusReg
	0, // AddressingMode.Provided
	0, // AddressingMode.Implicit
	0 // AddressingMode.UNK
];

static immutable InstructionTime[Instruction.Max] instructionCycleCounts_68000 =
[
	// [ word > reg, word > mem, long > reg, long > mem ]
	[ 4,  8,  6,  12 ], // MC68000_OR.B
	[ 4,  8,  6,  12 ], // MC68000_AND.B
	[ 4,  8,  6,  12 ], // MC68000_SUBI.B
	[ 4,  8,  6,  12 ], // MC68000_ADDI.B
	[ 6,  6,  0,  0 ],  // MC68000_ABCD
	[ 4,  8,  8,  12 ], // MC68000_EOR.B
	[ 4,  0,  6,  0 ],  // MC68000_CMP.B
	[ 6,  6,  0,  0 ],  // MC68000_SBCD
	[ 4,  8,  6,  12 ], // MC68000_OR.W
	[ 4,  8,  6,  12 ], // MC68000_AND.W
	[ 4,  8,  6,  12 ], // MC68000_SUBI.W
	[ 4,  8,  6,  12 ], // MC68000_ADDI.W
	[ 16, 16, 24, 24 ], // MC68000_MOVEP
	[ 4,  8,  8,  12 ], // MC68000_EOR.W
	[ 4,  0,  6,  0 ],  // MC68000_CMP.W
	[ 0,  0,  0,  0 ],  // MC68000_MOVEM
	[ 4,  8,  6,  12 ], // MC68000_OR.L
	[ 4,  8,  6,  12 ], // MC68000_AND.L
	[ 4,  8,  6,  12 ], // MC68000_SUBI.L
	[ 4,  8,  6,  12 ], // MC68000_ADDI.L
	[ 0,  0,  16, 0 ],  // MC68000_LINK
	[ 4,  8,  8,  12 ], // MC68000_EOR.L
	[ 4,  0,  6,  0 ],  // MC68000_CMP.L
	[ 0,  0,  12, 0 ],  // MC68000_UNLK

	[ 0,  4,  6,  0 ],  // MC68000_BTST
	[ 0,  8,  8,  0 ],  // MC68000_BCHG
	[ 0,  8,  10, 0 ],  // MC68000_BCLR
	[ 0,  8,  8,  0 ],  // MC68000_BSET

	[ 4,  8,  6,  12 ], // MC68000_NEGX.B
	[ 4,  8,  6,  12 ], // MC68000_CLR.B
	[ 4,  8,  6,  12 ], // MC68000_NEG.B
	[ 4,  8,  6,  12 ], // MC68000_NOT.B
	[ 4,  8,  6,  12 ], // MC68000_NEGX.W
	[ 4,  8,  6,  12 ], // MC68000_CLR.W
	[ 4,  8,  6,  12 ], // MC68000_NEG.W
	[ 4,  8,  6,  12 ], // MC68000_NOT.W
	[ 4,  8,  6,  12 ], // MC68000_NEGX.L
	[ 4,  8,  6,  12 ], // MC68000_CLR.L
	[ 4,  8,  6,  12 ], // MC68000_NEG.L
	[ 4,  8,  6,  12 ], // MC68000_NOT.L

	[ 0,  0,  132,0 ],  // MC68000_RESET
	[ 0,  0,  4,  0 ],  // MC68000_NOP
	[ 0,  0,  4,  0 ],  // MC68000_STOP
	[ 0,  0,  20, 0 ],  // MC68000_RTE
	[ 0,  0,  0,  0 ],  // MC68000_TRAP
	[ 0,  0,  16, 0 ],  // MC68000_RTS
	[ 0,  0,  4,  0 ],  // MC68000_TRAPV
	[ 0,  0,  20, 0 ],  // MC68000_RTR

	[ 6,  8,  8,  0 ],  // MC68000_ASR.B
	[ 6,  8,  8,  0 ],  // MC68000_LSR.B
	[ 6,  8,  8,  0 ],  // MC68000_ROXR.B
	[ 6,  8,  8,  0 ],  // MC68000_ROR.B
	[ 6,  8,  8,  0 ],  // MC68000_ASL.B
	[ 6,  8,  8,  0 ],  // MC68000_LSL.B
	[ 6,  8,  8,  0 ],  // MC68000_ROXL.B
	[ 6,  8,  8,  0 ],  // MC68000_ROL.B
	[ 6,  8,  8,  0 ],  // MC68000_ASR.W
	[ 6,  8,  8,  0 ],  // MC68000_LSR.W
	[ 6,  8,  8,  0 ],  // MC68000_ROXR.W
	[ 6,  8,  8,  0 ],  // MC68000_ROR.W
	[ 6,  8,  8,  0 ],  // MC68000_ASL.W
	[ 6,  8,  8,  0 ],  // MC68000_LSL.W
	[ 6,  8,  8,  0 ],  // MC68000_ROXL.W
	[ 6,  8,  8,  0 ],  // MC68000_ROL.W
	[ 6,  8,  8,  0 ],  // MC68000_ASR.L
	[ 6,  8,  8,  0 ],  // MC68000_LSR.L
	[ 6,  8,  8,  0 ],  // MC68000_ROXR.L
	[ 6,  8,  8,  0 ],  // MC68000_ROR.L
	[ 6,  8,  8,  0 ],  // MC68000_ASL.L
	[ 6,  8,  8,  0 ],  // MC68000_LSL.L
	[ 6,  8,  8,  0 ],  // MC68000_ROXL.L
	[ 6,  8,  8,  0 ],  // MC68000_ROL.L

	//[ 4,  8,  4,  12 ], // MC68000_MOVE.B
	//[ 4,  8,  4,  12 ], // MC68000_MOVE.W
	//[ 4,  8,  4,  12 ], // MC68000_MOVE.L
	//[ 4,  8,  4,  12 ], // MC68000_MOVEA.W
	//[ 4,  8,  4,  12 ], // MC68000_MOVEA.L
	[ 2,  4,  2,  6 ], // MC68000_MOVE.B
	[ 2,  4,  2,  6 ], // MC68000_MOVE.W
	[ 2,  4,  2,  6 ], // MC68000_MOVE.L
	[ 2,  4,  2,  6 ], // MC68000_MOVEA.W
	[ 2,  4,  2,  6 ], // MC68000_MOVEA.L

	[ 4,  8,  6,  12 ], // MC68000_ADD.B
	[ 4,  8,  6,  12 ], // MC68000_ADD.W
	[ 4,  8,  6,  12 ], // MC68000_ADD.L
	[ 8,  0,  6,  0 ],  // MC68000_ADDA.W
	[ 8,  0,  6,  0 ],  // MC68000_ADDA.L
	[ 4,  6,  8,  10 ], // MC68000_ADDX.B
	[ 4,  6,  8,  10 ], // MC68000_ADDX.W
	[ 4,  6,  8,  10 ], // MC68000_ADDX.L
	[ 4,  8,  6,  12 ], // MC68000_SUB.B
	[ 4,  8,  6,  12 ], // MC68000_SUB.W
	[ 4,  8,  6,  12 ], // MC68000_SUB.L
	[ 8,  0,  6,  0 ],  // MC68000_SUBA.W
	[ 8,  0,  6,  0 ],  // MC68000_SUBA.L
	[ 4,  6,  8,  10 ], // MC68000_SUBX.B
	[ 4,  6,  8,  10 ], // MC68000_SUBX.W
	[ 4,  6,  8,  10 ], // MC68000_SUBX.L

	[ 0,  0,  0,  0 ],  // MC68000_BRA
	[ 0,  0,  0,  0 ],  // MC68000_BSR
	[ 0,  0,  0,  0 ],  // MC68000_BHI
	[ 0,  0,  0,  0 ],  // MC68000_BLS
	[ 0,  0,  0,  0 ],  // MC68000_BCC
	[ 0,  0,  0,  0 ],  // MC68000_BCS
	[ 0,  0,  0,  0 ],  // MC68000_BNE
	[ 0,  0,  0,  0 ],  // MC68000_BEQ
	[ 0,  0,  0,  0 ],  // MC68000_BVC
	[ 0,  0,  0,  0 ],  // MC68000_BVS
	[ 0,  0,  0,  0 ],  // MC68000_BPL
	[ 0,  0,  0,  0 ],  // MC68000_BMI
	[ 0,  0,  0,  0 ],  // MC68000_BGE
	[ 0,  0,  0,  0 ],  // MC68000_BLT
	[ 0,  0,  0,  0 ],  // MC68000_BGT
	[ 0,  0,  0,  0 ],  // MC68000_BLE

	[ 0,  0,  0,  0 ],  // MC68000_DBT
	[ 0,  0,  0,  0 ],  // MC68000_DBF
	[ 0,  0,  0,  0 ],  // MC68000_DBHI
	[ 0,  0,  0,  0 ],  // MC68000_DBLS
	[ 0,  0,  0,  0 ],  // MC68000_DBCC
	[ 0,  0,  0,  0 ],  // MC68000_DBCS
	[ 0,  0,  0,  0 ],  // MC68000_DBNE
	[ 0,  0,  0,  0 ],  // MC68000_DBEQ
	[ 0,  0,  0,  0 ],  // MC68000_DBVC
	[ 0,  0,  0,  0 ],  // MC68000_DBVS
	[ 0,  0,  0,  0 ],  // MC68000_DBPL
	[ 0,  0,  0,  0 ],  // MC68000_DBMI
	[ 0,  0,  0,  0 ],  // MC68000_DBGE
	[ 0,  0,  0,  0 ],  // MC68000_DBLT
	[ 0,  0,  0,  0 ],  // MC68000_DBGT
	[ 0,  0,  0,  0 ],  // MC68000_DBLE

	[ 0,  0,  0,  0 ],  // MC68000_ST
	[ 0,  0,  0,  0 ],  // MC68000_SF
	[ 0,  0,  0,  0 ],  // MC68000_SHI
	[ 0,  0,  0,  0 ],  // MC68000_SLS
	[ 0,  0,  0,  0 ],  // MC68000_SCC
	[ 0,  0,  0,  0 ],  // MC68000_SCS
	[ 0,  0,  0,  0 ],  // MC68000_SNE
	[ 0,  0,  0,  0 ],  // MC68000_SEQ
	[ 0,  0,  0,  0 ],  // MC68000_SVC
	[ 0,  0,  0,  0 ],  // MC68000_SVS
	[ 0,  0,  0,  0 ],  // MC68000_SPL
	[ 0,  0,  0,  0 ],  // MC68000_SMI
	[ 0,  0,  0,  0 ],  // MC68000_SGE
	[ 0,  0,  0,  0 ],  // MC68000_SLT
	[ 0,  0,  0,  0 ],  // MC68000_SGT
	[ 0,  0,  0,  0 ],  // MC68000_SLE

	[ 0,  0,  4,  0 ],  // MC68000_MOVEQ
	[ 0,  0,  0,  0 ],  // MC68000_MOVESR
	[ 0,  0,  0,  0 ],  // MC68000_MOVEUSP
	[ 0,  0,  10, 0 ],  // MC68000_CHK
	[ 6,  0,  6,  0 ],  // MC68000_CMPA
	[ 0,  4,  0,  4 ],  // MC68000_CMPM
	[ 158,0,  158,0 ],  // MC68000_DIVS
	[ 140,0,  140,0 ],  // MC68000_DIVU
	[ 0,  0,  6,  0 ],  // MC68000_EXG
	[ 4,  0,  4,  0 ],  // MC68000_EXT
	[ 0,  0,  0,  0 ],  // MC68000_ILLEGAL
	[ 0,  0,  0,  8 ],  // MC68000_JMP
	[ 0,  0,  0,  16 ], // MC68000_JSR
	[ 0,  0,  4,  0 ],  // MC68000_LEA
	[ 38, 0,  38, 0 ],  // MC68000_MULS
	[ 38, 0,  38, 0 ],  // MC68000_MULU
	[ 6,  8,  0,  0 ],  // MC68000_NBCD
	[ 0,  0,  0,  12 ], // MC68000_PEA
	[ 0,  0,  4,  0 ],  // MC68000_SWAP
	[ 4,  14, 0,  0 ],  // MC68000_TAS
	[ 0,  0,  0,  0 ],  // MC68000_TRAPcc
	[ 4,  4,  4,  4 ],  // MC68000_TST.B
	[ 4,  4,  4,  4 ],  // MC68000_TST.W
	[ 4,  4,  4,  4 ],  // MC68000_TST.L
	[ 0,  0,  0,  0 ],  // MC68000_BKPT

	[ 0,  0,  0,  0 ],  // MC68010_RTD
	[ 0,  0,  0,  0 ],  // MC68010_MOVEC
	[ 0,  0,  0,  0 ],  // MC68010_MOVES
	[ 0,  0,  0,  0 ],  // MC68020_UNPK
];

const InstructionTime[Instruction.Max] instructionCycleCounts_68010 =
[
	// [ word > reg, word > mem, long > reg, long > mem ]
	[ 4,  8,  6,  12 ], // MC68000_ORI.B
	[ 4,  8,  6,  12 ], // MC68000_ANDI.B
	[ 4,  8,  6,  12 ], // MC68000_SUBI.B
	[ 4,  8,  6,  12 ], // MC68000_ADDI.B
	[ 6,  6,  0,  0 ],  // MC68000_ABCD
	[ 4,  8,  8,  12 ], // MC68000_EORI.B
	[ 4,  0,  6,  0 ],  // MC68000_CMPI.B
	[ 6,  6,  0,  0 ],  // MC68000_SBCD
	[ 4,  8,  6,  12 ], // MC68000_ORI.W
	[ 4,  8,  6,  12 ], // MC68000_ANDI.W
	[ 4,  8,  6,  12 ], // MC68000_SUBI.W
	[ 4,  8,  6,  12 ], // MC68000_ADDI.W
	[ 16, 16, 24, 24 ], // MC68000_MOVEP
	[ 4,  8,  8,  12 ], // MC68000_EORI.W
	[ 4,  0,  6,  0 ],  // MC68000_CMPI.W
	[ 0,  0,  0,  0 ],  // MC68000_MOVEM
	[ 4,  8,  6,  12 ], // MC68000_ORI.L
	[ 4,  8,  6,  12 ], // MC68000_ANDI.L
	[ 4,  8,  6,  12 ], // MC68000_SUBI.L
	[ 4,  8,  6,  12 ], // MC68000_ADDI.L
	[ 0,  0,  16, 0 ],  // MC68000_LINK
	[ 4,  8,  8,  12 ], // MC68000_EORI.L
	[ 4,  0,  6,  0 ],  // MC68000_CMPI.L
	[ 0,  0,  12, 0 ],  // MC68000_UNLK

	[ 0,  4,  6,  0 ],  // MC68000_BTST
	[ 0,  8,  8,  0 ],  // MC68000_BCHG
	[ 0,  10, 10, 0 ],  // MC68000_BCLR
	[ 0,  8,  8,  0 ],  // MC68000_BSET

	[ 4,  8,  6,  12 ], // MC68000_NEGX.B
	[ 4,  8,  6,  12 ], // MC68000_CLR.B
	[ 4,  8,  6,  12 ], // MC68000_NEG.B
	[ 4,  8,  6,  12 ], // MC68000_NOT.B
	[ 4,  8,  6,  12 ], // MC68000_NEGX.W
	[ 4,  8,  6,  12 ], // MC68000_CLR.W
	[ 4,  8,  6,  12 ], // MC68000_NEG.W
	[ 4,  8,  6,  12 ], // MC68000_NOT.W
	[ 4,  8,  6,  12 ], // MC68000_NEGX.L
	[ 4,  8,  6,  12 ], // MC68000_CLR.L
	[ 4,  8,  6,  12 ], // MC68000_NEG.L
	[ 4,  8,  6,  12 ], // MC68000_NOT.L

	[ 0,  0,  132,0 ],  // MC68000_RESET
	[ 0,  0,  4,  0 ],  // MC68000_NOP
	[ 0,  0,  4,  0 ],  // MC68000_STOP
	[ 0,  0,  20, 0 ],  // MC68000_RTE
	[ 0,  0,  0,  0 ],  // MC68000_TRAP
	[ 0,  0,  16, 0 ],  // MC68000_RTS
	[ 0,  0,  4,  0 ],  // MC68000_TRAPV
	[ 0,  0,  20, 0 ],  // MC68000_RTR

	[ 6,  8,  8,  0 ],  // MC68000_ASR.B
	[ 6,  8,  8,  0 ],  // MC68000_LSR.B
	[ 6,  8,  8,  0 ],  // MC68000_ROXR.B
	[ 6,  8,  8,  0 ],  // MC68000_ROR.B
	[ 6,  8,  8,  0 ],  // MC68000_ASL.B
	[ 6,  8,  8,  0 ],  // MC68000_LSL.B
	[ 6,  8,  8,  0 ],  // MC68000_ROXL.B
	[ 6,  8,  8,  0 ],  // MC68000_ROL.B
	[ 6,  8,  8,  0 ],  // MC68000_ASR.W
	[ 6,  8,  8,  0 ],  // MC68000_LSR.W
	[ 6,  8,  8,  0 ],  // MC68000_ROXR.W
	[ 6,  8,  8,  0 ],  // MC68000_ROR.W
	[ 6,  8,  8,  0 ],  // MC68000_ASL.W
	[ 6,  8,  8,  0 ],  // MC68000_LSL.W
	[ 6,  8,  8,  0 ],  // MC68000_ROXL.W
	[ 6,  8,  8,  0 ],  // MC68000_ROL.W
	[ 6,  8,  8,  0 ],  // MC68000_ASR.L
	[ 6,  8,  8,  0 ],  // MC68000_LSR.L
	[ 6,  8,  8,  0 ],  // MC68000_ROXR.L
	[ 6,  8,  8,  0 ],  // MC68000_ROR.L
	[ 6,  8,  8,  0 ],  // MC68000_ASL.L
	[ 6,  8,  8,  0 ],  // MC68000_LSL.L
	[ 6,  8,  8,  0 ],  // MC68000_ROXL.L
	[ 6,  8,  8,  0 ],  // MC68000_ROL.L

	//[ 4,  8,  4,  12 ], // MC68000_MOVE.B
	//[ 4,  8,  4,  12 ], // MC68000_MOVE.W
	//[ 4,  8,  4,  12 ], // MC68000_MOVE.L
	//[ 4,  8,  4,  12 ], // MC68000_MOVEA.W
	//[ 4,  8,  4,  12 ], // MC68000_MOVEA.L
	[ 2,  4,  2,  6 ], // MC68000_MOVE.B
	[ 2,  4,  2,  6 ], // MC68000_MOVE.W
	[ 2,  4,  2,  6 ], // MC68000_MOVE.L
	[ 2,  4,  2,  6 ], // MC68000_MOVEA.W
	[ 2,  4,  2,  6 ], // MC68000_MOVEA.L

	[ 4,  8,  6,  12 ], // MC68000_ADD.B
	[ 4,  8,  6,  12 ], // MC68000_ADD.W
	[ 4,  8,  6,  12 ], // MC68000_ADD.L
	[ 8,  0,  6,  0 ],  // MC68000_ADDA.W
	[ 8,  0,  6,  0 ],  // MC68000_ADDA.L
	[ 4,  6,  8,  10 ], // MC68000_ADDX.B
	[ 4,  6,  8,  10 ], // MC68000_ADDX.W
	[ 4,  6,  8,  10 ], // MC68000_ADDX.L
	[ 4,  8,  6,  12 ], // MC68000_SUB.B
	[ 4,  8,  6,  12 ], // MC68000_SUB.W
	[ 4,  8,  6,  12 ], // MC68000_SUB.L
	[ 8,  0,  6,  0 ],  // MC68000_SUBA.W
	[ 8,  0,  6,  0 ],  // MC68000_SUBA.L
	[ 4,  6,  8,  10 ], // MC68000_SUBX.B
	[ 4,  6,  8,  10 ], // MC68000_SUBX.W
	[ 4,  6,  8,  10 ], // MC68000_SUBX.L

	[ 0,  0,  0,  0 ],  // MC68000_BRA
	[ 0,  0,  0,  0 ],  // MC68000_BSR
	[ 0,  0,  0,  0 ],  // MC68000_BHI
	[ 0,  0,  0,  0 ],  // MC68000_BLS
	[ 0,  0,  0,  0 ],  // MC68000_BCC
	[ 0,  0,  0,  0 ],  // MC68000_BCS
	[ 0,  0,  0,  0 ],  // MC68000_BNE
	[ 0,  0,  0,  0 ],  // MC68000_BEQ
	[ 0,  0,  0,  0 ],  // MC68000_BVC
	[ 0,  0,  0,  0 ],  // MC68000_BVS
	[ 0,  0,  0,  0 ],  // MC68000_BPL
	[ 0,  0,  0,  0 ],  // MC68000_BMI
	[ 0,  0,  0,  0 ],  // MC68000_BGE
	[ 0,  0,  0,  0 ],  // MC68000_BLT
	[ 0,  0,  0,  0 ],  // MC68000_BGT
	[ 0,  0,  0,  0 ],  // MC68000_BLE
  
	[ 0,  0,  0,  0 ],  // MC68000_DBT
	[ 0,  0,  0,  0 ],  // MC68000_DBF
	[ 0,  0,  0,  0 ],  // MC68000_DBHI
	[ 0,  0,  0,  0 ],  // MC68000_DBLS
	[ 0,  0,  0,  0 ],  // MC68000_DBCC
	[ 0,  0,  0,  0 ],  // MC68000_DBCS
	[ 0,  0,  0,  0 ],  // MC68000_DBNE
	[ 0,  0,  0,  0 ],  // MC68000_DBEQ
	[ 0,  0,  0,  0 ],  // MC68000_DBVC
	[ 0,  0,  0,  0 ],  // MC68000_DBVS
	[ 0,  0,  0,  0 ],  // MC68000_DBPL
	[ 0,  0,  0,  0 ],  // MC68000_DBMI
	[ 0,  0,  0,  0 ],  // MC68000_DBGE
	[ 0,  0,  0,  0 ],  // MC68000_DBLT
	[ 0,  0,  0,  0 ],  // MC68000_DBGT
	[ 0,  0,  0,  0 ],  // MC68000_DBLE

	[ 0,  0,  0,  0 ],  // MC68000_ST
	[ 0,  0,  0,  0 ],  // MC68000_SF
	[ 0,  0,  0,  0 ],  // MC68000_SHI
	[ 0,  0,  0,  0 ],  // MC68000_SLS
	[ 0,  0,  0,  0 ],  // MC68000_SCC
	[ 0,  0,  0,  0 ],  // MC68000_SCS
	[ 0,  0,  0,  0 ],  // MC68000_SNE
	[ 0,  0,  0,  0 ],  // MC68000_SEQ
	[ 0,  0,  0,  0 ],  // MC68000_SVC
	[ 0,  0,  0,  0 ],  // MC68000_SVS
	[ 0,  0,  0,  0 ],  // MC68000_SPL
	[ 0,  0,  0,  0 ],  // MC68000_SMI
	[ 0,  0,  0,  0 ],  // MC68000_SGE
	[ 0,  0,  0,  0 ],  // MC68000_SLT
	[ 0,  0,  0,  0 ],  // MC68000_SGT
	[ 0,  0,  0,  0 ],  // MC68000_SLE

	[ 0,  0,  4,  0 ],  // MC68000_MOVEQ
	[ 0,  0,  0,  0 ],  // MC68000_MOVESR
	[ 0,  0,  0,  0 ],  // MC68000_MOVEUSP
	[ 0,  0,  10, 0 ],  // MC68000_CHK
	[ 6,  0,  6,  0 ],  // MC68000_CMPA
	[ 0,  4,  0,  4 ],  // MC68000_CMPM
	[ 122,0,  122,0 ],  // MC68000_DIVS
	[ 108,0,  108,0 ],  // MC68000_DIVU
	[ 0,  0,  6,  0 ],  // MC68000_EXG
	[ 4,  0,  4,  0 ],  // MC68000_EXT
	[ 0,  0,  0,  0 ],  // MC68000_ILLEGAL
	[ 0,  0,  0,  8 ],  // MC68000_JMP
	[ 0,  0,  0,  16 ], // MC68000_JSR
	[ 0,  0,  4,  0 ],  // MC68000_LEA
	[ 22, 0,  22, 0 ],  // MC68000_MULS
	[ 20, 0,  20, 0 ],  // MC68000_MULU
	[ 6,  8,  0,  0 ],  // MC68000_NBCD
	[ 0,  0,  0,  12 ], // MC68000_PEA
	[ 0,  0,  4,  0 ],  // MC68000_SWAP
	[ 4,  14, 0,  0 ],  // MC68000_TAS
	[ 0,  0,  0,  0 ],  // MC68000_TRAPcc
	[ 4,  4,  4,  4 ],  // MC68000_TST.B
	[ 4,  4,  4,  4 ],  // MC68000_TST.W
	[ 4,  4,  4,  4 ],  // MC68000_TST.L
	[ 0,  0,  0,  0 ],  // MC68000_BKPT

	[ 0,  0,  16, 0 ],  // MC68010_RTD
	[ 0,  0,  0,  0 ],  // MC68010_MOVEC
	[ 0,  0,  0,  0 ],  // MC68010_MOVES
	[ 0,  0,  0,  0 ],  // MC68020_UNPK
];

static immutable ubyte[SpecialInstructionTimings.Max] specialInstructionTimings_68000 =
[
	12, // SpecialInstructionTimings.MOVEM_Load
	8,  // SpecialInstructionTimings.MOVEM_Store
	6,  // SpecialInstructionTimings.MOVESR_SR2Reg
	8,  // SpecialInstructionTimings.MOVESR_SR2Mem
	12, // SpecialInstructionTimings.MOVESR_ToSR
	4,  // SpecialInstructionTimings.MOVEUSP_USP2Reg
	4,  // SpecialInstructionTimings.MOVEUSP_Reg2USP
	6,//10, // SpecialInstructionTimings.Bcc_Taken
	4,//8,  // SpecialInstructionTimings.Bcc_B_NotTaken
	6,//12, // SpecialInstructionTimings.Bcc_W_NotTaken
	8,//16, // SpecialInstructionTimings.Bcc_L_NotTaken
	6,//12, // SpecialInstructionTimings.DBcc_ccTrue
	8,//14, // SpecialInstructionTimings.DBcc_ccFalse_Expired
	4,//10, // SpecialInstructionTimings.DBcc_ccFalse_NotExpired
	4,  // SpecialInstructionTimings.Scc_ccTrue_Reg
	8,  // SpecialInstructionTimings.Scc_ccTrue_Mem
	6,  // SpecialInstructionTimings.Scc_ccFalse_Reg
	8,  // SpecialInstructionTimings.Scc_ccFalse_Mem
];

static immutable ubyte[SpecialInstructionTimings.Max] specialInstructionTimings_68010 =
[
	12, // SpecialInstructionTimings.MOVEM_Load
	8,  // SpecialInstructionTimings.MOVEM_Store
	4,  // SpecialInstructionTimings.MOVESR_SR2Reg
	8,  // SpecialInstructionTimings.MOVESR_SR2Mem
	12, // SpecialInstructionTimings.MOVESR_ToSR
	6,  // SpecialInstructionTimings.MOVEUSP_USP2Reg
	6,  // SpecialInstructionTimings.MOVEUSP_Reg2USP
	6,//10, // SpecialInstructionTimings.Bcc_Taken
	4,//6,  // SpecialInstructionTimings.Bcc_B_NotTaken
	6,//10, // SpecialInstructionTimings.Bcc_W_NotTaken
	8,//14, // SpecialInstructionTimings.Bcc_L_NotTaken
	10, // SpecialInstructionTimings.DBcc_ccTrue
	16, // SpecialInstructionTimings.DBcc_ccFalse_Expired
	10, // SpecialInstructionTimings.DBcc_ccFalse_NotExpired
	4,  // SpecialInstructionTimings.Scc_ccTrue_Reg
	8,  // SpecialInstructionTimings.Scc_ccTrue_Mem
	4,  // SpecialInstructionTimings.Scc_ccFalse_Reg
	8,  // SpecialInstructionTimings.Scc_ccFalse_Mem
];

static string[] gpSizeMnemonics = [ "B", "W", "L", "Q" ];
static string[] gpAddressModes =
[
	" %s",       // AddressingMode.DReg
	" %s",       // AddressingMode.AReg
	" (%s)",     // AddressingMode.Ind
	" (%s)+",    // AddressingMode.IndPostInc
	" -(%s)",    // AddressingMode.IndPreDec
	" (%s,%s)",  // AddressingMode.IndOffset
	" (%s,%s,%s",// AddressingMode.IndIndex
	"",          // AddressingMode.Special
	" (%s).W",   // AddressingMode.AbsW
	" (%s).L",   // AddressingMode.AbsL
	" (%s,%s)",  // AddressingMode.OffsetPC
	" (%s,%s,%s",// AddressingMode.IndexPC
	" %s",       // AddressingMode.Imm
	" %s",       // AddressingMode.Imm16
	" %s",       // AddressingMode.StatusReg
	" %s",       // AddressingMode.Provided
	""           // AddressingMode.Implicit
];

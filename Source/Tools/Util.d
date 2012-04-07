module demu.tools.util;

import std.string;
import std.algorithm;

struct StaticArray(size_t count, T = char)
{
	alias data this;

	T[count] buffer;
	uint len;

	@property size_t capacity() const nothrow { return buffer.length; }

	@property T[] data() { return buffer[0..len]; }
	@property void data(in T[] s) { buffer[0..len] = s[]; }

	void opAssign(in T[] data)
	{
		if(data.ptr == buffer.ptr)
		{
			len = data.length;
			return;
		}

		if(data.length > buffer.length)
			throw new Exception("Buffer too small!");
		buffer[0 .. data.length] = data[];
		len = data.length;
	}

	void opOpAssign(string op : "~")(in T[] data)
	{
		if(len + data.length > buffer.length)
			throw new Exception("Out of space!");
		buffer[len .. len + data.length] = data[];
		len += data.length;
	}

	void opOpAssign(string op : "~")(in T data)
	{
		this ~= (&data)[0..1];
	}

	T[] format(A...)(A args)
	{
		T[] t = sformat(buffer, args);
		len = t.length;
		return t;
	}

	T[] formatAppend(A...)(A args)
	{
		T[] t = sformat(buffer[len..$], args);
		len += t.length;
		return data;
	}

	size_t find(T t) const
	{
		foreach(i; 0..len)
		{
			if(buffer[i] == t)
				return i;
		}
		return len;
	}

	size_t rFind(T t) const
	{
		for(size_t i = len - 1; i >= 0; --i)
		{
			if(buffer[i] == t)
				return i;
		}
		return len;
	}
}

template StaticString(size_t length, T = char)
{
	alias StaticArray!(length - uint.sizeof/T.sizeof) StaticString;
}

int AtoI(size_t Base = 0)(const(char)[] str)
{
	if(str.length == 0)
		return 0;

	int base = Base;
	int returnValue;
	size_t i;
	char digit;
	bool bNegate, bValidDigitsFound;

	while(str[i] == ' ' || str[i] == '\t')
		++i;
	if(str[i] == '-')
	{
		bNegate = true;
		++i;
	}
	if((base == 0 || base == 16) && str[i] == '0' && (str[i+1] == 'x' || str[i+1] == 'X'))
	{
		base = 16;
		i += 2; // Skip over 0x prefix for hex numbers
	}
	if((base == 0 || base == 16) && str[i] == '$')
	{
		base = 16;
		++i; // Skip over $ prefix for hex numbers
	}
	if((base == 0 || base == 2) && str[i] == '0' && (str[i+1] == 'b' || str[i+1] == 'B'))
	{
		base = 2;
		i += 2; // Skip over 0b prefix for binary numbers
	}
	if(!base)
		base = 10;

	foreach(j; i..str.length)
	{
		digit = str[j];
		if (digit >= '0' && digit < min('0' + 10, '0' + base))
			digit = cast(char)(digit - '0');
		else if (base >= 16)
		{
			if (digit >= 'a' && digit < min('a' + 26, base - 10 + 'a'))
				digit = cast(char)(digit - 'a' + 10);
			else if (digit >= 'A' && digit < min('A' + 26, base - 10 + 'A'))
				digit = cast(char)(digit - 'A' + 10);
			else
				break;
		}
		else
			break;
		if(digit < base)
			returnValue = returnValue * base + digit;
		else
			break;
		bValidDigitsFound = true;
	}

	if(bNegate)
		returnValue = -returnValue;

	return returnValue;
}

module demu.main;

import core.runtime;
import core.thread;

import demu.emulator.systemregistry;

import demu.emulator.machine;
import demu.emulator.display;

import demu.rommanager.romdatabase;
import demu.rommanager.game;

struct MFInitParams
{
	const(char)* pAppTitle;		//*< A title used to represent the application */

	void* hInstance;			//*< The WIN32 hInstance paramater supplied to WinMain() */
	void* hWnd;					//*< An optional hWnd to a WIN32 window that will contain the viewport */

	const(char)* pCommandLine;	//*< Pointer to the command line string */

	int argc;					//*< The argc parameter supplied to main() */
	const(char)** argv;			//*< The argv paramater supplied to main() */
};

extern (C) int MFMain(MFInitParams *pInitParams);

version(Windows)
{
	//import std.c.windows.windows;
	import win32.windows;
	import win32.wingdi;

	extern (Windows) int WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
	{
	    int result;

	    void exceptionHandler(Throwable e)
	    {
	        throw e;
	    }

	    try
	    {
	        Runtime.initialize(&exceptionHandler);

	        result = myWinMain(hInstance, hPrevInstance, lpCmdLine, nCmdShow);

	        Runtime.terminate(&exceptionHandler);
	    }
	    catch (Throwable o)		// catch any uncaught exceptions
	    {
	        MessageBox(null, cast(char *)o.toString(), "Error", MB_OK | MB_ICONEXCLAMATION);
	        result = 0;		// failed
	    }

	    return result;
	}
	
private:
	__gshared DisplayDimensions windowSize;
	__gshared HBITMAP bm;

	int myWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
	{
//		MFInitParams init;
//		MFMain(&init);

		// init the database
		db = new RomDatabase();

		// find a game
		RomInstance* rom = db.FindRom("FantasyZone");

		// create the machine
		Machine machine = CreateSystem(rom, db);
//		Machine machine = CreateSystem(rom, db, "Ox10c");

		// init the display
		windowSize = machine.GetDisplay().DisplaySize;
		HWND hWnd = CreateDisplay(hInstance, windowSize, nCmdShow);

		uint[] frameBuffer = new uint[640*480];
		bm = CreateBitmap(windowSize.width, windowSize.height, 1, 32, frameBuffer.ptr);

		// run the game
		bool bQuit = false;
		while(!bQuit)
		{
			uint startTime = GetTickCount();

			MSG msg;
			while(PeekMessage(&msg, null, 0, 0, PM_NOREMOVE))
			{
				if(GetMessage(&msg, null, 0, 0) == 0)
				{
					bQuit = true;
				}
				else
				{
					TranslateMessage(&msg); 
					DispatchMessage(&msg);
				}
			}

			machine.UpdateMachine();
			machine.Draw(frameBuffer);

			// render the image
			SetBitmapBits(bm, windowSize.numPixels * 4, frameBuffer.ptr);
			InvalidateRect(hWnd, null, false);

			uint endTime = GetTickCount();
			int ms = endTime - startTime;
			if(ms < 16)
				Thread.sleep(dur!"msecs"(16 - ms));
		}

		return 0;
	}

	void Paint(HWND hWnd)
	{
		BITMAP bmi;
		PAINTSTRUCT ps;

		HDC hdc = BeginPaint(hWnd, &ps);

		HDC hdcMem = CreateCompatibleDC(hdc);
		HBITMAP hbmOld = SelectObject(hdcMem, bm);

		GetObject(bm, bmi.sizeof, &bmi);

		BOOL b = BitBlt(hdc, 0, 0, bmi.bmWidth, bmi.bmHeight, hdcMem, 0, 0, SRCCOPY);

		SelectObject(hdcMem, hbmOld);
		DeleteDC(hdcMem);

		EndPaint(hWnd, &ps);
	}

	HWND CreateDisplay(HINSTANCE hInstance, DisplayDimensions size, int nCmdShow)
	{
		WNDCLASSA wc;
		wc.lpfnWndProc = &WndProc;
		wc.hInstance = hInstance;
		wc.lpszClassName = "demu";
		wc.style = CS_HREDRAW | CS_VREDRAW;
		RegisterClassA(&wc);

		HWND hWnd = CreateWindowEx(0, "demu", "DEmu", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 240, 120, null, null, hInstance, null);

		ResizeDisplay(hWnd, size);

		ShowWindow(hWnd, nCmdShow);
	    UpdateWindow(hWnd);

		return hWnd;
	}

	void ResizeDisplay(HWND hWnd, DisplayDimensions size)
	{
		RECT r;
		r.right = size.width;
		r.bottom = size.height;
		AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);

		RECT pos;
		GetWindowRect(hWnd, &pos);
		MoveWindow(hWnd, pos.left, pos.top, r.right - r.left, r.bottom - r.top, FALSE);
	}

	extern(Windows) LRESULT WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
	{
		switch(msg)
		{
			case WM_CLOSE:
				DestroyWindow(hWnd);
				break;
			case WM_DESTROY:
				PostQuitMessage(0);
				break;
			case WM_PAINT:
				Paint(hWnd);
				break;
			default:
				return DefWindowProc(hWnd, msg, wParam, lParam);
		}
		return 0;
	}
}
else
{
	int main(string args[])
	{
		MFInitParams init;
		MFMain(&init);
		return 0;
	}
}

private:

RomDatabase db;

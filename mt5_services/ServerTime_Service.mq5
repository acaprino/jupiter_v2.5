//+------------------------------------------------------------------+
//|                             ServerTime_Service                   |
//|          Service to write server time in Unix timestamp in JSON  |
//|          Includes lockfile mechanism for Python integration      |
//+------------------------------------------------------------------+
#property service
#property copyright "Copyright 2024, Alfio Caprino."
#property link      "https://www.mql5.com"
#property version   "1.00"

// File paths for JSON output and lockfile
#define JSON_FILE_PATH "server_timestamp.json"
#define LOCK_FILE_NAME "ServerTime_Service_lockfile.sem"

//+------------------------------------------------------------------+
//| Service main loop                                                |
//+------------------------------------------------------------------+
void OnStart()
  {
   do
     {
      CreateLockFile();

      WriteTimestampToJson();

      DeleteLockFile();

      datetime now = TimeTradeServer();
      int seconds_past_minute = ((int)now) % 60; // Seconds since the last full minute
      int seconds_until_next_minute = 60 - seconds_past_minute; // Seconds until the next full minute
      Sleep(seconds_until_next_minute * 1000);
     }
   while(true);
  }


//+------------------------------------------------------------------+
//| Function to create a lock file                                   |
//+------------------------------------------------------------------+
void CreateLockFile()
  {
   int lockFile = FileOpen(LOCK_FILE_NAME, FILE_WRITE | FILE_TXT);
   if(lockFile != INVALID_HANDLE)
     {
      FileWrite(lockFile, "Calendar generation in progress");
      FileClose(lockFile);
     }
   else
     {
      Print("[ERROR] Unable to create lock file: ", LOCK_FILE_NAME);
     }
  }

//+------------------------------------------------------------------+
//| Function to delete the lock file                                 |
//+------------------------------------------------------------------+
void DeleteLockFile()
  {
   if(!FileDelete(LOCK_FILE_NAME))
      Print("[ERROR] Unable to delete lock file: ", LOCK_FILE_NAME);
  }

//+------------------------------------------------------------------+
//| Function to write the timestamp to a JSON file                  |
//+------------------------------------------------------------------+
void WriteTimestampToJson()
  {
   MqlDateTime dt_utc={};
   MqlDateTime dt_server={};
   datetime    time_utc=TimeGMT(dt_utc);  
   datetime    time_server =TimeTradeServer(dt_server);
   int         difference  = int((time_server-time_utc) / 3600.0);
   
   string json_content = "{\n"
                         "    \"time_utc\": \"" + (string(time_utc)) + "\",\n"
                         "    \"time_server\": \"" + (string(time_server)) + "\",\n"
                         "    \"time_utc_unix\": " + IntegerToString((long)time_utc) + ",\n"
                         "    \"time_server_unix\": " + IntegerToString((long)time_server) + ",\n"
                         "    \"time_difference\": " + IntegerToString(difference) + "\n"
                         "}";
      
   int handle = FileOpen(JSON_FILE_PATH, FILE_READ | FILE_WRITE | FILE_ANSI | FILE_TXT);
   if(handle == INVALID_HANDLE)
     {
      int error_code = GetLastError();
      Print("[ERROR] Unable to open file: ", JSON_FILE_PATH, ". Error code: ", error_code);
      return;
     }

   FileWrite(handle, json_content);
   FileClose(handle);
   int error_code = GetLastError();
   if(error_code != 0)
     {
      Print("[ERROR] Error occurred after closing the file. Error code: ", error_code);
     }
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                              MarketHours_Service.mq5             |
//|                          Copyright 2024, Alfio Caprino.          |
//|                                https://www.mql5.com              |
//+------------------------------------------------------------------+
#property service
#property copyright "Copyright 2024, Alfio Caprino."
#property link      "https://www.mql5.com"
#property version   "1.00"

#define FILE_NAME           "symbol_sessions.json"
#define LOCK_FILE_NAME      "MarketHours_Service.lock"
#define TEMP_FILE_NAME      "symbol_sessions.tmp"
#define INTERVAL_SECONDS    3600
#define MAX_RETRIES         5
#define RETRY_DELAY_MS      1000

//+------------------------------------------------------------------+
//| Service Entry Point                                              |
//+------------------------------------------------------------------+
void OnStart()
  {
   while(true)
     {
      if(CreateLockFile())
        {
         bool success = WriteFile();
         DeleteLockFile();

         if(!success)
           {
            Print("[ERROR] Write operation failed after maximum retries.");
           }
        }
      else
        {
         Print("[ERROR] Could not create lock file. Skipping this interval.");
        }

      SleepUntilNextInterval();
     }
  }

//+------------------------------------------------------------------+
//| Create the lock file                                             |
//+------------------------------------------------------------------+
bool CreateLockFile()
  {
   int retries = 0;

   while(retries < MAX_RETRIES)
     {
      int lockFile = FileOpen(LOCK_FILE_NAME, FILE_WRITE | FILE_TXT);
      if(lockFile != INVALID_HANDLE)
        {
         FileWrite(lockFile, "Calendar generation in progress");
         FileClose(lockFile);
         Print("[INFO] Lock file created: ", LOCK_FILE_NAME);
         return true;
        }
      else
        {
         Print("[ERROR] Unable to create lock file: ", GetLastError());
         Sleep(RETRY_DELAY_MS);
         retries++;
        }
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Delete the lock file                                             |
//+------------------------------------------------------------------+
void DeleteLockFile()
  {
   int retries = 0;

   while(retries < MAX_RETRIES)
     {
      if(FileIsExist(LOCK_FILE_NAME))
        {
         if(FileDelete(LOCK_FILE_NAME))
           {
            Print("[INFO] Lock file deleted: ", LOCK_FILE_NAME);
            return;
           }
         else
           {
            Print("[ERROR] Unable to delete lock file: ", GetLastError());
            Sleep(RETRY_DELAY_MS);
            retries++;
           }
        }
      else
        {
         // Lock file does not exist; no need to delete
         return;
        }
     }

   Print("[ERROR] Failed to delete lock file after maximum retries.");
  }

//+------------------------------------------------------------------+
//| Sleep until the next scheduled interval                          |
//+------------------------------------------------------------------+
void SleepUntilNextInterval()
  {
   datetime now = TimeCurrent();
   int seconds_past_interval = (int)(now % INTERVAL_SECONDS);
   int seconds_until_next_interval = INTERVAL_SECONDS - seconds_past_interval;

   Sleep(seconds_until_next_interval * 1000);
  }

//+------------------------------------------------------------------+
//| Write the content to a JSON file using a temporary file          |
//+------------------------------------------------------------------+
bool WriteFile()
{
   string json = GetContent();
   int retryCount = 0;
   bool writeSuccess = false;

   // Convert json string to UTF-8 byte array without including the null terminator
   uchar json_utf8[];
   int json_length = StringToCharArray(json, json_utf8, 0, StringLen(json), CP_UTF8);

   // Write to temporary file
   while(!writeSuccess && retryCount < MAX_RETRIES)
   {
      if(FileIsExist(TEMP_FILE_NAME))
         FileDelete(TEMP_FILE_NAME);

      int tempFileHandle = FileOpen(TEMP_FILE_NAME, FILE_WRITE | FILE_BIN);
      if(tempFileHandle == INVALID_HANDLE)
      {
         Print("[ERROR] Error opening temporary file for writing: ", GetLastError());
         Sleep(RETRY_DELAY_MS);
         retryCount++;
         continue;
      }

      // Optionally write UTF-8 BOM (remove this block if not needed)
      /*
      uchar bom[] = {0xEF, 0xBB, 0xBF};
      int bomBytesWritten = FileWriteArray(tempFileHandle, bom, 0, ArraySize(bom));
      if(bomBytesWritten != ArraySize(bom))
      {
         Print("[ERROR] Failed to write UTF-8 BOM to temporary file: ", GetLastError());
         FileClose(tempFileHandle);
         Sleep(RETRY_DELAY_MS);
         retryCount++;
         continue;
      }
      */

      // Write JSON content as UTF-8 encoded byte array
      int bytesWritten = FileWriteArray(tempFileHandle, json_utf8, 0, json_length);
      FileClose(tempFileHandle);

      if(bytesWritten != json_length)
      {
         Print("[ERROR] Failed to write JSON content to temporary file: ", GetLastError());
         Sleep(RETRY_DELAY_MS);
         retryCount++;
         continue;
      }

      writeSuccess = true;
   }

   if(!writeSuccess)
   {
      Print("[ERROR] Failed to write to temporary file after maximum retries.");
      return false;
   }

   // Move temporary file to final destination
   retryCount = 0;
   bool moveSuccess = false;

   while(!moveSuccess && retryCount < MAX_RETRIES)
   {
      if(FileIsExist(FILE_NAME))
      {
         if(!FileDelete(FILE_NAME))
         {
            Print("[ERROR] Failed to delete existing file: ", GetLastError());
            Sleep(RETRY_DELAY_MS);
            retryCount++;
            continue;
         }
      }

      if(FileMove(TEMP_FILE_NAME, 0, FILE_NAME, FILE_REWRITE))
      {
         moveSuccess = true;
      }
      else
      {
         Print("[ERROR] Error moving temporary file to final destination: ", GetLastError());
         Sleep(RETRY_DELAY_MS);
         retryCount++;
      }
   }

   if(!moveSuccess)
   {
      Print("[ERROR] Failed to move temporary file after maximum retries.");
      // Clean up temporary file
      if(FileIsExist(TEMP_FILE_NAME))
         FileDelete(TEMP_FILE_NAME);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Service program start function                                   |
//+------------------------------------------------------------------+
string GetContent()
  {
   string symbols[] =
     {
      "AUDUSD", "EURUSD", "GBPUSD", "NZDUSD", "USDCAD", "USDCHF", "USDJPY",
      "AUDCAD", "AUDCHF", "AUDJPY", "AUDNZD", "CADCHF", "CADJPY", "CHFJPY",
      "EURAUD", "EURCAD", "EURCHF", "EURGBP", "EURJPY", "EURNZD",
      "GBPAUD", "GBPCAD", "GBPCHF", "GBPJPY", "GBPNZD",
      "NZDCAD", "NZDCHF", "NZDJPY", "XAUUSD"
     };

   while(true)
     {
      CreateLockFile();

      string json_content = "{\n";
      json_content += "  \"symbols\": [\n";


      for(int i = 0; i < ArraySize(symbols); i++)
        {
         string symbol = symbols[i];
         json_content += GetSymbolSessionData(symbol);

         // Add a comma unless it's the last symbol
         if(i < ArraySize(symbols) - 1)
            json_content += ",\n";
         else
            json_content += "\n";
        }

      json_content += "  ]\n";
      json_content += "}\n";

      return json_content;
     }
  }
//+------------------------------------------------------------------+
//| Get trading session data for a single symbol in JSON format      |
//+------------------------------------------------------------------+
string GetSymbolSessionData(string symbol)
  {
   int SESSION_INDEX = 0;
   string json = "    {\n";
   json += "      \"symbol\": \"" + symbol + "\",\n";
   json += "      \"sessions\": [\n";
   for(int i = MONDAY; i <= FRIDAY; i++)
     {
      datetime date_from, date_to;
      if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)i, SESSION_INDEX, date_from, date_to))
        {
         Print("SymbolInfoSessionTrade() failed for symbol ", symbol, ". Error ", GetLastError());
         continue;
        }

      // Convert ENUM_DAY_OF_WEEK to readable string
      string week_day = DayOfWeekToString((ENUM_DAY_OF_WEEK)i);

      json += "        {\n";
      json += "          \"day\": \"" + week_day + "\",\n";
      json += "          \"start_time\": \"" +  TimeToString(date_from, TIME_MINUTES)  + "\",\n";
      json += "          \"end_time\": \"" +  TimeToString(date_to, TIME_MINUTES)  + "\"\n";
      json += "        }";

      if(i < FRIDAY)
         json += ",\n";
      else
         json += "\n";
     }

   json += "      ]\n";
   json += "    }";
   return json;
  }

//+------------------------------------------------------------------+
//| Convert ENUM_DAY_OF_WEEK to human-readable weekday string         |
//+------------------------------------------------------------------+
string DayOfWeekToString(ENUM_DAY_OF_WEEK day_of_week)
  {
   switch(day_of_week)
     {
      case MONDAY:
         return "Monday";
      case TUESDAY:
         return "Tuesday";
      case WEDNESDAY:
         return "Wednesday";
      case THURSDAY:
         return "Thursday";
      case FRIDAY:
         return "Friday";
      case SATURDAY:
         return "Saturday";
      case SUNDAY:
         return "Sunday";
      default:
         return "Unknown";  // Should not occur for valid input
     }
  }
//+------------------------------------------------------------------+

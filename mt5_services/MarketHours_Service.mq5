//+------------------------------------------------------------------+
//|                              MarketHours_Service.mq5             |
//|                          Copyright 2024, Alfio Caprino.          |
//|                                https://www.mql5.com              |
//+------------------------------------------------------------------+
#property service
#property copyright "Copyright 2024, Alfio Caprino."
#property link      "https://www.mql5.com"
#property version   "1.00"

#define JSON_FILE_PATH "symbol_sessions.json"
#define LOCK_FILE_NAME "MarketHours_Service.lock"
#define SESSION_INDEX 0

//+------------------------------------------------------------------+
//| Service program start function                                   |
//+------------------------------------------------------------------+
void OnStart()
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

      int handle = FileOpen(JSON_FILE_PATH, FILE_READ | FILE_WRITE | FILE_ANSI | FILE_TXT);
      if(handle == INVALID_HANDLE)
        {
         int error_code = GetLastError();
         Print("[ERROR] Unable to open file: ", JSON_FILE_PATH, ". Error code: ", error_code);
         return;
        }

      uchar bom[] = {0xEF, 0xBB, 0xBF};
      FileWriteArray(handle, bom, 0, ArraySize(bom));
      FileWrite(handle, json_content);
      FileClose(handle);
      int error_code = GetLastError();
      if(error_code != 0)
        {
         Print("[ERROR] Error occurred after closing the file. Error code: ", error_code);
        }


      DeleteLockFile();

      datetime now = TimeTradeServer();
      int seconds_past_hour = ((int)now) % (60*60); // Seconds since the last full minute
      int seconds_until_next_hour = (60*60) - seconds_past_hour; // Seconds until the next full minute
      Sleep(seconds_until_next_hour * 1000);
     }
  }

//+------------------------------------------------------------------+
//| Get trading session data for a single symbol in JSON format      |
//+------------------------------------------------------------------+
string GetSymbolSessionData(string symbol)
  {
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
//| Capitalize the first letter of a string                          |
//+------------------------------------------------------------------+
string Capitalize(string str)
  {
   if(StringLen(str) > 0)
     {
      string first_letter = StringSubstr(str, 0, 1);
      string remaining_letters = StringSubstr(str, 1);
      return StringToUpper(first_letter) + StringToLower(remaining_letters);
     }
   return str;
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                              MarketHours_Service.mq5             |
//|                          Copyright 2024, Alfio Caprino.          |
//|                                https://www.mql5.com              |
//+------------------------------------------------------------------+
#property service
#property copyright "Copyright 2024, Alfio Caprino."
#property link      "https://www.mql5.com"
#property version   "1.00"

#define SESSION_INDEX 0  // Define the session index (e.g., 0 for the first session)

//+------------------------------------------------------------------+
//| Service program start function                                   |
//+------------------------------------------------------------------+
void OnStart()
  {
   string json_file_path = "symbol_sessions.json";      // JSON file path
   string semaphore_file_path = "MarketHours_Service.lock"; // Semaphore file path
   
   while(true)
     {
      // Step 1: Create semaphore file
      if(!FileCreateSemaphore(semaphore_file_path))
        {
         Print("Error creating semaphore file. Exiting.");
         return;
        }
      
      // Step 2: Gather data for all symbols
      string json_result = "{\n";
      json_result += "  \"symbols\": [\n";
      
      int total_symbols = SymbolsTotal(false);  // Get all available symbols (not hidden)
      
      for(int i = 0; i < total_symbols; i++)
        {
         string symbol = SymbolName(i, false);  // Get symbol name
         json_result += GetSymbolSessionData(symbol);
         
         // Add a comma unless it's the last symbol
         if(i < total_symbols - 1) 
            json_result += ",\n";
         else 
            json_result += "\n";
        }
      
      json_result += "  ]\n";
      json_result += "}\n";
      
      // Step 3: Write JSON to file
      int file_handle = FileOpen(json_file_path, FILE_WRITE|FILE_TXT);
      if(file_handle == INVALID_HANDLE)
        {
         Print("Error opening file for writing: ", GetLastError());
         FileDeleteSemaphore(semaphore_file_path);  // Remove semaphore before exiting
         return;
        }
      
      FileWriteString(file_handle, json_result);  // Write JSON data to file
      FileClose(file_handle);  // Close the file
      
      // Step 4: Remove semaphore file
      if(!FileDeleteSemaphore(semaphore_file_path))
        {
         Print("Error deleting semaphore file.");
        }
      
      // Step 5: Wait for 1 minute
      Sleep(60000);  // 1-minute interval
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
      json += "          \"start_time\": \"" + TimeToString(date_from, TIME_MINUTES) + "\",\n";
      json += "          \"end_time\": \"" + TimeToString(date_to, TIME_MINUTES) + "\"\n";
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
      case MONDAY:    return "Monday";
      case TUESDAY:   return "Tuesday";
      case WEDNESDAY: return "Wednesday";
      case THURSDAY:  return "Thursday";
      case FRIDAY:    return "Friday";
      default:        return "Unknown";  // Should not occur for valid input
     }
  }

//+------------------------------------------------------------------+
//| Create a semaphore file                                          |
//+------------------------------------------------------------------+
bool FileCreateSemaphore(string semaphore_file)
  {
   int file_handle = FileOpen(semaphore_file, FILE_WRITE|FILE_TXT);
   if(file_handle == INVALID_HANDLE)
     {
      Print("Error creating semaphore file: ", GetLastError());
      return false;
     }
   FileClose(file_handle);
   return true;
  }

//+------------------------------------------------------------------+
//| Delete a semaphore file                                          |
//+------------------------------------------------------------------+
bool FileDeleteSemaphore(string semaphore_file)
  {
   if(!FileDelete(semaphore_file))
     {
      Print("Error deleting semaphore file: ", GetLastError());
      return false;
     }
   return true;
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

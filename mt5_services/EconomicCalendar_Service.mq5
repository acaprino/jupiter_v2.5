///+------------------------------------------------------------------+
//|                        Economic Calendar Service                 |
//|                                      Copyright 2024, CompanyName |
//|                                       http://www.companyname.net |
//+------------------------------------------------------------------+
#property service
#property copyright "Copyright 2024, Alfio Caprino."
#property link      "https://www.mql5.com"
#property version   "1.00"

#define FILE_NAME           "economic_calendar.json"
#define LOCK_FILE_NAME      "EconomicCalendar_Service.lock"
#define TEMP_FILE_NAME      "economic_calendar.tmp"
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
//| Event structure definition                                       |
//+------------------------------------------------------------------+
struct Event
  {
   int               country_id;
   string            country_name;
   string            country_code;
   string            country_currency;
   string            country_currency_symbol;
   string            country_url_name;
   int               event_id;
   int               event_type;
   int               event_sector;
   int               event_frequency;
   int               event_time_mode;
   int               event_unit;
   int               event_importance;
   int               event_multiplier;
   int               event_digits;
   string            event_source_url;
   string            event_code;
   string            event_name;
   datetime          event_time;
   int               event_period;
   int               event_revision;
   double            actual_value;
   double            prev_value;
   double            revised_prev_value;
   double            forecast_value;
   int               impact_type;
  };

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string GetContent()
  {
   datetime today = RemoveTimeFromDatetime(TimeCurrent());
   datetime startDateTime = today;
   datetime endDateTime = AddMonths(today, 12);

   Print("Writing events from ", FormatDateTime(startDateTime), " to ", FormatDateTime(endDateTime));

   MqlCalendarCountry countries[];
   int countries_count = CalendarCountries(countries);

   Event myEvents[];

   for(int i = 0; i < countries_count; i++)
     {
      Print("Country: ", countries[i].code);
      MqlCalendarEvent events[];
      int event_count = CalendarEventByCountry(countries[i].code, events);
      Print("Country events count: ", event_count);
      
      if(event_count <= 0)
         continue;

      for(int j = 0; j < event_count; j++)
        {
         // Exclude events with CALENDAR_TIMEMODE_TENTATIVE or CALENDAR_TIMEMODE_NOTIME
         if(events[j].time_mode == CALENDAR_TIMEMODE_TENTATIVE || events[j].time_mode == CALENDAR_TIMEMODE_NOTIME)
            continue;
          Print("Event id: ", events[j].id);
         MqlCalendarValue values[];
         int value_count = CalendarValueHistoryByEvent(events[j].id, values, startDateTime, endDateTime);
         Print("Event values count in dates range: ", value_count);
          
         if(value_count <= 0)
            continue;

         // Populate Event structures and store them in the array
         for(int k = 0; k < value_count; k++)
           {
            Event myEvent;
            PopulateEvent(myEvent, countries[i], events[j], values[k]);
            string event_json = SerializeEventToJson(myEvent);
            Print("Event populated: ", event_json);
            ArrayResize(myEvents, ArraySize(myEvents) + 1);
            myEvents[ArraySize(myEvents) - 1] = myEvent;
           }
        }
     }

   return SerializeEventsToJson(myEvents);
  }


//+------------------------------------------------------------------+
//| Populate an Event structure with data                            |
//+------------------------------------------------------------------+
void PopulateEvent(Event &myEvent, MqlCalendarCountry &country, MqlCalendarEvent &event, MqlCalendarValue &value)
  {
   myEvent.country_id            = country.id;
   myEvent.country_name          = country.name;
   myEvent.country_code          = country.code;
   myEvent.country_currency      = country.currency;
   myEvent.country_currency_symbol = country.currency_symbol;
   myEvent.country_url_name      = country.url_name;
   myEvent.event_id              = event.id;
   myEvent.event_type            = event.type;
   myEvent.event_sector          = event.sector;
   myEvent.event_frequency       = event.frequency;
   myEvent.event_time_mode       = event.time_mode;
   myEvent.event_unit            = event.unit;
   myEvent.event_importance      = event.importance;
   myEvent.event_multiplier      = event.multiplier;
   myEvent.event_digits          = event.digits;
   myEvent.event_source_url      = event.source_url;
   myEvent.event_code            = event.event_code;
   myEvent.event_name            = event.name;
   myEvent.event_time            = value.time;
   myEvent.event_period          = value.period;
   myEvent.event_revision        = value.revision;
   myEvent.actual_value          = value.actual_value;
   myEvent.prev_value            = value.prev_value;
   myEvent.revised_prev_value    = value.revised_prev_value;
   myEvent.forecast_value        = value.forecast_value;
   myEvent.impact_type           = value.impact_type;
  }

//+------------------------------------------------------------------+
//| Serialize an Event structure to JSON format                      |
//+------------------------------------------------------------------+
string SerializeEventToJson(const Event &e)
{
   return StringFormat(
             "{\"country_id\":%d,\"country_name\":\"%s\",\"country_code\":\"%s\","
             "\"country_currency\":\"%s\",\"country_currency_symbol\":\"%s\","
             "\"country_url_name\":\"%s\",\"event_id\":%d,\"event_type\":%d,"
             "\"event_sector\":%d,\"event_frequency\":%d,\"event_time_mode\":%d,"
             "\"event_unit\":%d,\"event_importance\":%d,\"event_multiplier\":%d,"
             "\"event_digits\":%d,\"event_source_url\":\"%s\",\"event_code\":\"%s\","
             "\"event_name\":\"%s\",\"event_time\":\"%s\",\"event_period\":%d,"
             "\"event_revision\":%d,\"actual_value\":%.2f,\"prev_value\":%.2f,"
             "\"revised_prev_value\":%.2f,\"forecast_value\":%.2f,\"impact_type\":%d}",
             e.country_id, 
             EscapeDoubleQuotes(e.country_name), 
             EscapeDoubleQuotes(e.country_code), 
             EscapeDoubleQuotes(e.country_currency),
             EscapeDoubleQuotes(e.country_currency_symbol), 
             EscapeDoubleQuotes(e.country_url_name), 
             e.event_id,
             e.event_type, 
             e.event_sector, 
             e.event_frequency, 
             e.event_time_mode,
             e.event_unit, 
             e.event_importance, 
             e.event_multiplier, 
             e.event_digits,
             EscapeDoubleQuotes(e.event_source_url), 
             EscapeDoubleQuotes(e.event_code), 
             EscapeDoubleQuotes(e.event_name),
             TimeToString(e.event_time, TIME_DATE | TIME_MINUTES), 
             e.event_period,
             e.event_revision, 
             e.actual_value, 
             e.prev_value, 
             e.revised_prev_value,
             e.forecast_value, 
             e.impact_type);
}

//+------------------------------------------------------------------+
//| Serialize an array of Event structures into a JSON array         |
//+------------------------------------------------------------------+
string SerializeEventsToJson(const Event &myEvents[])
  {
   Print("SerializeEventsToJson start...");
   string jsonArray = "["; // Start JSON array
   for(int i = 0; i < ArraySize(myEvents); i++)
     {
      if(i > 0)
         jsonArray += ","; // Add comma between objects
      jsonArray += SerializeEventToJson(myEvents[i]); // Serialize each event
     }
   jsonArray += "]"; // End JSON array
   Print("SerializeEventsToJson end...", jsonArray);
   return jsonArray; // Return serialized JSON array
  }

//+------------------------------------------------------------------+
//| Utility to format a datetime value into DD/MM/YYYY format        |
//+------------------------------------------------------------------+
string FormatDateTime(datetime time)
  {
   MqlDateTime dt;
   TimeToStruct(time, dt);
   return StringFormat("%02d/%02d/%04d", dt.day, dt.mon, dt.year);
  }

//+------------------------------------------------------------------+
//| Utility to remove the time part of a datetime                    |
//+------------------------------------------------------------------+
datetime RemoveTimeFromDatetime(datetime time)
  {
   MqlDateTime dt;
   TimeToStruct(time, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| Utility to escape double quotes for JSON compatibility           |
//+------------------------------------------------------------------+
string EscapeDoubleQuotes(string text)
  {
   StringReplace(text, "\"", "\\\"");
   return text;
  }

//+------------------------------------------------------------------+
//| Add or subtract days from a given datetime                       |
//+------------------------------------------------------------------+
datetime AddDays(datetime currentDate, int daysToAdjust)
  {
// Convert datetime into MqlDateTime structure
   MqlDateTime structDate;
   TimeToStruct(currentDate, structDate);

// Days in each month
   int daysInMonth[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

// Leap year check for February
   if(structDate.mon == 2 && ((structDate.year % 4 == 0 && structDate.year % 100 != 0) || (structDate.year % 400 == 0)))
      daysInMonth[1] = 29;

// Add or subtract days
   structDate.day += daysToAdjust;

// Handle overflow and underflow of days
   while(structDate.day > daysInMonth[structDate.mon - 1])   // Overflow case
     {
      structDate.day -= daysInMonth[structDate.mon - 1];
      structDate.mon++;
      if(structDate.mon > 12)
        {
         structDate.mon = 1;
         structDate.year++;
        }

      // Adjust for leap year if month is February
      if(structDate.mon == 2 && ((structDate.year % 4 == 0 && structDate.year % 100 != 0) || (structDate.year % 400 == 0)))
         daysInMonth[1] = 29;
      else
         daysInMonth[1] = 28;
     }

   while(structDate.day <= 0)   // Underflow case
     {
      structDate.mon--;
      if(structDate.mon < 1)
        {
         structDate.mon = 12;
         structDate.year--;
        }

      // Adjust for leap year if month is February
      if(structDate.mon == 2 && ((structDate.year % 4 == 0 && structDate.year % 100 != 0) || (structDate.year % 400 == 0)))
         daysInMonth[1] = 29;
      else
         daysInMonth[1] = 28;

      structDate.day += daysInMonth[structDate.mon - 1];
     }

// Convert the modified structure back to datetime
   datetime adjustedDate = StructToTime(structDate);
   return adjustedDate;  // Return the adjusted datetime
  }
//+------------------------------------------------------------------+
//| Add or subtract months from a given datetime                     |
//+------------------------------------------------------------------+
datetime AddMonths(datetime currentDate, int monthsToAdjust)
  {
   MqlDateTime structDate;
   TimeToStruct(currentDate, structDate); // Converts the datetime into a MqlDateTime structure

   structDate.mon += monthsToAdjust; // Adjusts the month by the specified amount

   while(structDate.mon > 12) // Handle case for month overflow
     {
      structDate.mon -= 12; // Decreases the month by 12
      structDate.year += 1; // Moves to the next year
     }

   while(structDate.mon <= 0) // Handle case for month underflow
     {
      structDate.mon += 12; // Increases the month by 12
      structDate.year -= 1; // Moves to the previous year
     }

// Handles cases where the day is not valid for the new month
   int daysInMonth[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
// Leap year check for February
   if(structDate.mon == 2 && ((structDate.year % 4 == 0 && structDate.year % 100 != 0) || (structDate.year % 400 == 0)))
      daysInMonth[1] = 29; // February has 29 days in a leap year

   if(structDate.day > daysInMonth[structDate.mon - 1])
     {
      structDate.day = daysInMonth[structDate.mon - 1]; // Adjusts the day to the last day of the month if necessary
     }

   datetime adjustedDate = StructToTime(structDate); // Converts the modified structure back into datetime

   return adjustedDate; // Returns the adjusted datetime
  }

//+------------------------------------------------------------------+

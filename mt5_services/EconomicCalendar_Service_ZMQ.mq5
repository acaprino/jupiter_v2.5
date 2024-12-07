///+------------------------------------------------------------------+
//|                        Economic Calendar Service                 |
//|                                      Copyright 2024, CompanyName |
//|                                       http://www.companyname.net |
//+------------------------------------------------------------------+
#include <Zmq/Zmq.mqh>
#property service

// Definizione dei flag ZeroMQ
#define ZMQ_DONTWAIT 1
#define ZMQ_SNDMORE 2
#define ZMQ_ROUTER 6

//+------------------------------------------------------------------+
//| Service Entry Point                                              |
//+------------------------------------------------------------------+
void OnStart()
  {
// Inizializza il contesto ZeroMQ
   Context context();
   int port = 5557;
// Crea un socket ROUTER
   Socket router(context, ZMQ_ROUTER);
   router.bind("tcp://127.0.0.1:" + port);

   Print("Servizio ZMQ Router avviato sulla porta " + port);

   while(true)
     {
      ZmqMsg identity;    // Identità del client
      ZmqMsg request;     // Messaggio di richiesta

      // Riceve l'identità del client
      if(!router.recv(identity, ZMQ_DONTWAIT))
        {
         // Nessuna richiesta ricevuta, pausa per evitare uso eccessivo della CPU
         Sleep(100);
         continue;
        }

      string client_id = identity.getData();
      PrintFormat("Richiesta ricevuta da %s", client_id);

      // Riceve il messaggio
      if(!router.recv(request))
        {
         Print("Errore nella ricezione del messaggio");
         continue;
        }


      string received = request.getData();
      PrintFormat("Richiesta ricevuta da %s: %s", client_id, received);

      string params[];
      int count = StringSplit(received, ':', params);

      // Estrai i dati dalla stringa
      string country_code = params[0];            // Codice del paese
      long start_unix = (long)StringToInteger(params[1]); // Data di inizio in formato UNIX
      long end_unix = (long)StringToInteger(params[2]);   // Data di fine in formato UNIX

      // Converti UNIX timestamp in datetime
      datetime start_datetime = (datetime)start_unix;
      datetime end_datetime = (datetime)end_unix;

      // Stampa per debug
      PrintFormat("Codice paese: %s, Inizio: %s, Fine: %s",
                  country_code,
                  TimeToString(start_datetime, TIME_DATE | TIME_MINUTES),
                  TimeToString(end_datetime, TIME_DATE | TIME_MINUTES));

      string json_content = GetContent(start_datetime, end_datetime, country_code);

      router.sendMore(client_id);
      router.send(json_content);

      PrintFormat("Risposta inviata a %s: %s", client_id, json_content);
     }
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
string GetContent(datetime start_time, datetime end_time, string country_code)
{
   // Verifica che le date siano valide
   if(start_time >= end_time)
   {
      Print("Errore: start_time deve essere precedente a end_time.");
      return "{\"error\": \"Invalid date range\"}";
   }

   Print("Writing events from ", FormatDateTime(start_time), " to ", FormatDateTime(end_time), " for country: ", country_code);

   MqlCalendarCountry countries[];
   int countries_count = CalendarCountries(countries);

   Event myEvents[];
   bool country_found = false;

   // Filtra direttamente il paese richiesto
   for(int i = 0; i < countries_count; i++)
   {
      // Se il paese corrente non corrisponde, salta al prossimo
      if(countries[i].code != country_code)
         continue;

      country_found = true; // Il paese è stato trovato
      Print("Country found: ", countries[i].code);

      MqlCalendarEvent events[];
      int event_count = CalendarEventByCountry(countries[i].code, events);
      Print("Country events count: ", event_count);

      if(event_count <= 0)
         continue;

      for(int j = 0; j < event_count; j++)
      {
         // Esclude eventi con CALENDAR_TIMEMODE_TENTATIVE o CALENDAR_TIMEMODE_NOTIME
         if(events[j].time_mode == CALENDAR_TIMEMODE_TENTATIVE || events[j].time_mode == CALENDAR_TIMEMODE_NOTIME)
            continue;

         Print("Event id: ", events[j].id);
         MqlCalendarValue values[];
         int value_count = CalendarValueHistoryByEvent(events[j].id, values, start_time, end_time);
         Print("Event values count in date range: ", value_count);

         if(value_count <= 0)
            continue;

         // Popola le strutture Event e salvale nell'array
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

   // Se il paese non è stato trovato
   if(!country_found)
   {
      Print("Errore: il codice del paese specificato non è stato trovato: ", country_code);
      return "{\"error\": \"Country code not found\"}";
   }

   // Serializza tutti gli eventi in formato JSON
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

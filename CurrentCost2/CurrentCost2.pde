/*

this example for fully function (official)ethernet code for arduino & pachube. 
including the use of DHCP library, Watchdog timer & manually reset the shield.

hardware note: 
You will need Arduino Duemilanove w/ atmega328. (the sketch is quite big)
You will need LadyADA's bootloader for Watchdog timer to work. (http://www.ladyada.net/library/arduino/bootloader.html)
You will need some modification to reset the ethernet shield.

library note: 
Special thanks to Jordan Terrell(http://blog.jordanterrell.com/) and Georg Kaindl(http://gkaindl.com) for DHCP library

*/

#include <Ethernet.h>
#include <EthernetDHCP.h>
#include <EthernetDNS.h>
#include <NewSoftSerial.h>
#include <Flash.h>

#define ID              1       // If you have more than 1 unit on same network change the unit ID to another number
#define FEED            6502    // Remote feed number here, this has to be your own feed
#define APIKEY          ""      // Enter your Pachube API key here

#define BAUD            56700   // Baud rate of Current Cost device (57600 for Envi, 9600 for Classic)
#define RXPIN           2       // Pin data from Current Cost is sent to
#define TXPIN           3       // Pin data for Current Cost is sent from
#define RESETPIN        9       // Pin reset wire is connected to

char hostName[] = "ARDUINO";    // Host name to use when obtaining DHCP lease

byte mac[] = { 0xDA, 0xAD, 0xCA, 0xEF, 0xFE,  byte(ID) };

// Pachube
char pacDomain[] = "pachube.com";
byte pacAddr[4]; // = { 192, 168, 0, 4 };

NewSoftSerial softSerial(RXPIN, TXPIN);

//char buffer[166];
char buffer[256];
int pos = 0;

int reading = 0;

Server server = Server(23);

uint8_t * heapptr, * stackptr;
void check_mem() {
  stackptr = (uint8_t *)malloc(4);          // use stackptr temporarily
  heapptr = stackptr;                     // save value of heap pointer
  free(stackptr);      // free up the memory again (sets stackptr to 0)
  stackptr =  (uint8_t *)(SP);           // save value of stack pointer
  // Display free memory
  Serial << F("Memory: ");
  Serial.println(stackptr - heapptr);
}

void setup()
{
  // Bring up serial connections
  softSerial.begin(57600);
  Serial.begin(9600);
  
  // Reset ethernet shield
  Serial << F("Reset ethernet shield... ");
  pinMode(RESETPIN, OUTPUT);
  digitalWrite(RESETPIN, LOW);
  delay(200);
  digitalWrite(RESETPIN, HIGH);
  delay(200);
  Serial << F("[OK]\r\n");
  
  // Assign IP address via DHCP
  Serial << F("Attempting to obtain DHCP lease... ");
  EthernetDHCP.setHostName(hostName);
  EthernetDHCP.begin(mac);
  Serial << F("[OK]\r\n");
  
  // Start telnet server
  server.begin();
  
  // Display DHCP details
  const byte* ipAddr = EthernetDHCP.ipAddress();
  const byte* gatewayAddr = EthernetDHCP.gatewayIpAddress();
  const byte* dnsAddr = EthernetDHCP.dnsIpAddress();
  Serial << F("IP address: ");
  Serial.println(ip_to_str(ipAddr));
  server << F("IP address:" );
  Serial << F("Gateway IP address: ");
  Serial.println(ip_to_str(gatewayAddr));
  Serial << F("DNS IP address: ");
  Serial.println(ip_to_str(dnsAddr));
  
  // Get IP address for Pachube
  Serial << F("Getting IP address for Pachube... ");
  EthernetDNS.setDNSServer(dnsAddr);
  DNSError err = EthernetDNS.resolveHostName(pacDomain, pacAddr);
  if (DNSSuccess == err)
  {
    Serial << F("[OK]\r\n");
    Serial << F("Pachube IP address: ");
    Serial.println(ip_to_str(pacAddr));
  }
  else 
  {
    Serial << F("[FAIL]\r\n");
    if (DNSTimedOut == err)
    {
      Serial << F("Timed out\r\n");
    }
    else if (DNSNotFound == err)
    {
      Serial << F("Does not exist\r\n");
    }
    else
    {
      Serial << F("Failed with error code ");
      Serial.print((int)err, DEC);
    }
  }
  
  check_mem();
}

void loop()
{
  // Read into buffer
  while (softSerial.available())
  {
    int inByte = softSerial.read();
    buffer[pos] = inByte;
    Serial.print(inByte, BYTE);
    server.print(inByte, BYTE);
    pos = (pos + 1) % 256;
      
    // Check for msg entity end
    int msgIndex = indexOf(buffer, pos, "</msg>", 6);
    if (msgIndex != -1)
    {
      Serial.println();
      
      // Check for sensor number
      int snsrStartIndex = indexOf(buffer, pos, "<sensor>", 8);
      int snsrEndIndex = indexOf(buffer, pos, "</sensor>", 9);
      
      if ((snsrStartIndex != -1) && (snsrEndIndex != -1))
      {
        Serial << F("Sensor: ");
        printSubstr(buffer, snsrStartIndex + 8, snsrEndIndex);
        Serial.println();
      }
      
      // Check for temperature reading
      int tmprStartIndex = indexOf(buffer, pos, "<tmpr>", 6);
      int tmprEndIndex = indexOf(buffer, pos, "</tmpr>", 7);
      
      if ((tmprStartIndex != -1) && (tmprEndIndex != -1))
      {
        Serial << F("Temperature: ");
        printSubstr(buffer, tmprStartIndex + 6, tmprEndIndex);
        Serial.println();
      }
      
      // Check for energy reading
      int wattStartIndex = indexOf(buffer, pos, "<watts>", 7);
      int wattEndIndex = indexOf(buffer, pos, "</watts>", 8);
      if ((wattStartIndex != 0) && (wattEndIndex != 0))
      {
        Serial << F("Energy: ");
        printSubstr(buffer, wattStartIndex + 7, wattEndIndex);
        Serial.println();
      }
      
      // Gas meter reading?
      if ((snsrStartIndex != 0) && (snsrEndIndex != 0) && (wattStartIndex != 0) && (wattEndIndex != 0))
      {
        if (buffer[snsrStartIndex + 8] == 49)
        {
          if (buffer[wattStartIndex + 9] == 53)
          {
            reading++;
          }
          Serial << F("Gas reading: ");
          Serial.println(reading);
        }
        
        if ((buffer[snsrStartIndex + 8] == 48) && (tmprStartIndex != 0) && (tmprEndIndex != 0))
        {
          // Upload to Pachube
          Serial << F("Uploading to Pachube... ");
          Client client = Client(pacAddr, 80);
          client.stop();
          
          if (client.connect())
          {
            static char readingString[16];
            int readingLength = sprintf(readingString, "%d", reading);
            int contentLength = (tmprEndIndex - (tmprStartIndex + 7)) + (wattEndIndex - (wattStartIndex + 7)) + 2 + readingLength;
              
            client.print("PUT http://www.pachube.com/api/feeds/");
            client.print(FEED);
            client.println(".csv HTTP/1.1");
            client.println("Host: www.pachube.com");
            client.print("X-PachubeApiKey: ");
            client.println(APIKEY);
        
            client.println("User-Agent: CurrentCost for Arduino");
            client.print("Content-Type: text/csv\r\nContent-Length: ");
            client.println(contentLength);
            client.println("Connection: close");
            client.println();
      
            for (int i = wattStartIndex + 7; i < wattEndIndex; i++)
            {
              client.print(buffer[i], BYTE);
            }
            client.print(",");
            
            for (int i = tmprStartIndex + 6; i < tmprEndIndex; i++)
            {
              client.print(buffer[i], BYTE);
            }
            client.print(",");
            
            client.print(readingString);
            client.println();
            
            while (client.available() || client.connected())
            {
              while (client.available())
              {
                char c = client.read();
                //Serial.print(c);
              }
            
              if (!client.connected())
              {
                //Serial.println();
                //Serial << F("disconnecting.\r\n");
                client.stop();
              }
            }
            Serial << F("[OK]\r\n");
          }
          else
          {
            Serial << F("[FAIL]\r\n");      
          }
          client.stop();

        }
      }
      
      check_mem();
            
      // Reset buffer
      pos = 0;
    }
  }
  
  // Maintain lease
  EthernetDHCP.maintain();
}

int indexOf(char haystack[], int heystackLen, char needle[], int needleLen)
{
  int i; int j;
  for (i = 0; i < heystackLen - needleLen; i++)
  {
    for (j = 0; j < needleLen; j++)
    {
      if (haystack[i + j] != needle[j])
      {
        goto skip;
      }
    }
    goto found;
    skip:;
  }
  return -1;
  found:
  return i;
}

void printSubstr(char haystack[], int startIndex, int endIndex)
{
  for (int i = startIndex; i < endIndex; i++)
  {
    Serial.print(haystack[i], BYTE);
  }
}

const char* ip_to_str(const uint8_t* ipAddr)
{
  static char buf[16];
  sprintf(buf, "%d.%d.%d.%d\0", ipAddr[0], ipAddr[1], ipAddr[2], ipAddr[3]);
  return buf;
}

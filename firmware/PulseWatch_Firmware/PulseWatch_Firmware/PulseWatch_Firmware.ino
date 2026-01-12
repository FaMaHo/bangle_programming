/*
 * PulseWatch AI - T-Watch S3 Plus Firmware
 * Battery-Efficient Medical Monitoring System
 * 
 * Features:
 * - 3 swipeable pages with proper touch handling
 * - Auto-sleep after inactivity (saves battery)
 * - Wakes on power button press
 * - BLE data transmission for heart rate monitoring
 * - Works independently when disconnected from laptop
 * 
 * Power Consumption:
 * - Active: ~60-80mA (display on, BLE active)
 * - Display Sleep: ~20-30mA (display off, BLE active, monitoring continues)
 * - Works independently when disconnected from laptop
 * - Maintains BLE connection during display sleep for continuous monitoring
 */

#include <LilyGoLib.h>
#include <LV_Helper.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ==========================================
// BLUETOOTH CONFIGURATION
// ==========================================
#define SERVICE_UUID           "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_ACCEL_UUID        "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CHAR_HEARTRATE_UUID    "8ec414d4-2866-4126-b333-65977935047b"
#define BLE_DEVICE_NAME        "T-Watch-S3-Plus"

// ==========================================
// POWER MANAGEMENT SETTINGS
// Medical monitoring requires continuous BLE
// so we use display sleep (not CPU sleep)
// ==========================================
#define SLEEP_TIMEOUT_MS       30000    // 30 seconds of inactivity → display off
#define SCREEN_BRIGHTNESS      200       // 0-255, lower = better battery

// BLE Objects
BLEServer* pServer = NULL;
BLECharacteristic* pAccelCharacteristic = NULL;
BLECharacteristic* pHRCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// ==========================================
// UI OBJECTS - 3 Screens
// ==========================================
lv_obj_t *screen1, *screen2, *screen3;
uint8_t currentScreen = 0;  // 0=main, 1=HR monitor, 2=summary

// Page 1 - Main Watch Face
lv_obj_t *ui_TimeLabel;
lv_obj_t *ui_BatteryLabel;
lv_obj_t *ui_ConnectionIcon;
lv_obj_t *ui_MainHRLabel;
lv_obj_t *ui_PageIndicator1;

// Page 2 - Heart Monitor
lv_obj_t *ui_Page2Title;
lv_obj_t *ui_HRBigLabel;
lv_obj_t *ui_HRRangeLabel;
lv_obj_t *ui_CaptureButton;
lv_obj_t *ui_PageIndicator2;

// Page 3 - Today Summary
lv_obj_t *ui_Page3Title;
lv_obj_t *ui_RecordingTimeLabel;
lv_obj_t *ui_EventsLabel;
lv_obj_t *ui_LastSyncLabel;
lv_obj_t *ui_PageIndicator3;

// Touch tracking
int16_t touch_start_x = 0;
bool touch_active = false;

// ==========================================
// DATA VARIABLES
// ==========================================
int simulatedHR = 70;
int hrDirection = 1;
int minHR = 70;
int maxHR = 70;
unsigned long lastActivityTime = 0;    // For sleep timeout
unsigned long lastDataUpdateTime = 0;  // For data updates
unsigned long sessionStartTime = 0;
int eventsToday = 0;
unsigned long lastSyncTime = 0;
bool manualCaptureActive = false;
bool powerButtonPressed = false;

// Sleep management
RTC_DATA_ATTR int wakeCount = 0;      // Persists through sleep

// ==========================================
// BLE CALLBACKS
// ==========================================
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      lastSyncTime = millis();
      Serial.println("✅ App Connected!");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("❌ App Disconnected");
    }
};

// ==========================================
// HELPER FUNCTIONS
// ==========================================

String getFormattedTime() {
  unsigned long seconds = millis() / 1000;
  int hours = (seconds / 3600) % 24;
  int minutes = (seconds / 60) % 60;
  
  char timeStr[6];
  snprintf(timeStr, sizeof(timeStr), "%02d:%02d", hours, minutes);
  return String(timeStr);
}

String formatDuration(unsigned long milliseconds) {
  unsigned long seconds = milliseconds / 1000;
  int hours = seconds / 3600;
  int minutes = (seconds % 3600) / 60;
  
  char durationStr[16];
  snprintf(durationStr, sizeof(durationStr), "%dh %dm", hours, minutes);
  return String(durationStr);
}

String getLastSyncText() {
  if (!deviceConnected) return "Not synced";
  
  unsigned long elapsed = (millis() - lastSyncTime) / 1000;
  if (elapsed < 60) return "Just now";
  
  int minutes = elapsed / 60;
  if (minutes < 60) {
    char syncStr[16];
    snprintf(syncStr, sizeof(syncStr), "%d min ago", minutes);
    return String(syncStr);
  }
  
  int hours = minutes / 60;
  char syncStr[16];
  snprintf(syncStr, sizeof(syncStr), "%d hr ago", hours);
  return String(syncStr);
}

int getBatteryPercent() {
  // Get real battery percentage from AXP2101 power management chip
  return instance.pmu.getBatteryPercent();
}

// ==========================================
// PAGE NAVIGATION
// ==========================================
void switchToScreen(uint8_t screenNum) {
    if (screenNum > 2) return;
    
    currentScreen = screenNum;
    
    if (screenNum == 0) {
        lv_scr_load(screen1);
        Serial.println("📍 Page 1: Main Watch Face");
    } else if (screenNum == 1) {
        lv_scr_load(screen2);
        Serial.println("📍 Page 2: Heart Monitor");
    } else if (screenNum == 2) {
        lv_scr_load(screen3);
        Serial.println("📍 Page 3: Today Summary");
    }
    
    // Reset activity timer on page change
    lastActivityTime = millis();
}

void nextScreen() {
    if (currentScreen < 2) {
        switchToScreen(currentScreen + 1);
    }
}

void prevScreen() {
    if (currentScreen > 0) {
        switchToScreen(currentScreen - 1);
    }
}

// ==========================================
// TOUCH HANDLER (Using Proper API)
// ==========================================
void handleTouch() {
    // Proper API: getPoint needs x and y arrays
    int16_t x_array[1];
    int16_t y_array[1];
    
    // Check for touch points
    uint8_t touchCount = instance.touch.getPoint(x_array, y_array, 1);
    
    if (touchCount > 0) {
        int16_t current_x = x_array[0];
        int16_t current_y = y_array[0];
        
        if (!touch_active) {
            // Touch just started - record starting position
            touch_active = true;
            touch_start_x = current_x;
            Serial.printf("Touch started at X=%d\n", current_x);
        } else {
            // Touch is ongoing - check for swipe
            int16_t dx = current_x - touch_start_x;
            
            // Detect swipe (>60 pixel movement)
            if (abs(dx) > 60) {
                if (dx < 0) {
                    // Swipe left - next page
                    Serial.println("👈 Swipe LEFT detected!");
                    nextScreen();
                } else {
                    // Swipe right - previous page  
                    Serial.println("👉 Swipe RIGHT detected!");
                    prevScreen();
                }
                touch_active = false;
            }
        }
        
        // Update activity time on any touch
        lastActivityTime = millis();
        
    } else {
        // No touch detected - reset
        if (touch_active) {
            Serial.println("Touch ended");
            touch_active = false;
        }
    }
}

// ==========================================
// BUTTON CALLBACKS
// ==========================================
static void capture_button_event_cb(lv_event_t * e) {
    manualCaptureActive = true;
    eventsToday++;
    Serial.println("🫀 Manual Capture Triggered!");
    
    lv_obj_t * btn = lv_event_get_target(e);
    lv_obj_set_style_bg_color(btn, lv_color_hex(0x00FF00), LV_PART_MAIN);
    
    // Update activity time
    lastActivityTime = millis();
}

// ==========================================
// UI SETUP - PAGE 1: MAIN WATCH FACE
// ==========================================
void setupPage1() {
    screen1 = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(screen1, lv_color_hex(0x000000), LV_PART_MAIN);
    
    // Connection Icon (Top Left)
    ui_ConnectionIcon = lv_label_create(screen1);
    lv_label_set_text(ui_ConnectionIcon, LV_SYMBOL_BLUETOOTH);
    lv_obj_set_style_text_color(ui_ConnectionIcon, lv_color_hex(0xFF0000), LV_PART_MAIN);
    lv_obj_set_style_text_font(ui_ConnectionIcon, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_align(ui_ConnectionIcon, LV_ALIGN_TOP_LEFT, 10, 10);

    // Battery (Top Right)
    ui_BatteryLabel = lv_label_create(screen1);
    lv_label_set_text(ui_BatteryLabel, LV_SYMBOL_BATTERY_3 " 50%");
    lv_obj_set_style_text_color(ui_BatteryLabel, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_set_style_text_font(ui_BatteryLabel, &lv_font_montserrat_12, LV_PART_MAIN);
    lv_obj_align(ui_BatteryLabel, LV_ALIGN_TOP_RIGHT, -10, 10);

    // Time (Center)
    ui_TimeLabel = lv_label_create(screen1);
    lv_label_set_text(ui_TimeLabel, "10:09");
    lv_obj_set_style_text_font(ui_TimeLabel, &lv_font_montserrat_48, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_TimeLabel, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_align(ui_TimeLabel, LV_ALIGN_CENTER, 0, -20);

    // Heart Rate
    ui_MainHRLabel = lv_label_create(screen1);
    lv_label_set_text(ui_MainHRLabel, "HR: 72");
    lv_obj_set_style_text_font(ui_MainHRLabel, &lv_font_montserrat_28, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_MainHRLabel, lv_color_hex(0xFF6B6B), LV_PART_MAIN);
    lv_obj_align(ui_MainHRLabel, LV_ALIGN_CENTER, 0, 40);
    
    // Page indicator
    ui_PageIndicator1 = lv_label_create(screen1);
    lv_label_set_text(ui_PageIndicator1, "● ○ ○");
    lv_obj_set_style_text_color(ui_PageIndicator1, lv_color_hex(0x888888), LV_PART_MAIN);
    lv_obj_set_style_text_font(ui_PageIndicator1, &lv_font_montserrat_12, LV_PART_MAIN);
    lv_obj_align(ui_PageIndicator1, LV_ALIGN_BOTTOM_MID, 0, -10);
}

// ==========================================
// UI SETUP - PAGE 2: HEART MONITOR
// ==========================================
void setupPage2() {
    screen2 = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(screen2, lv_color_hex(0x000000), LV_PART_MAIN);
    
    // Title
    ui_Page2Title = lv_label_create(screen2);
    lv_label_set_text(ui_Page2Title, "Heart Rate");
    lv_obj_set_style_text_font(ui_Page2Title, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_Page2Title, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_align(ui_Page2Title, LV_ALIGN_TOP_MID, 0, 20);

    // Big HR
    ui_HRBigLabel = lv_label_create(screen2);
    lv_label_set_text(ui_HRBigLabel, "72 BPM");
    lv_obj_set_style_text_font(ui_HRBigLabel, &lv_font_montserrat_32, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_HRBigLabel, lv_color_hex(0xFF6B6B), LV_PART_MAIN);
    lv_obj_align(ui_HRBigLabel, LV_ALIGN_CENTER, 0, -30);

    // Range
    ui_HRRangeLabel = lv_label_create(screen2);
    lv_label_set_text(ui_HRRangeLabel, "Today: 60-120 BPM\nAvg: 68 BPM");
    lv_obj_set_style_text_font(ui_HRRangeLabel, &lv_font_montserrat_12, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_HRRangeLabel, lv_color_hex(0xAAAAAA), LV_PART_MAIN);
    lv_obj_set_style_text_align(ui_HRRangeLabel, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui_HRRangeLabel, LV_ALIGN_CENTER, 0, 15);

    // Capture Button
    ui_CaptureButton = lv_btn_create(screen2);
    lv_obj_set_size(ui_CaptureButton, 180, 50);
    lv_obj_align(ui_CaptureButton, LV_ALIGN_BOTTOM_MID, 0, -40);
    lv_obj_set_style_bg_color(ui_CaptureButton, lv_color_hex(0xE8A598), LV_PART_MAIN);
    lv_obj_add_event_cb(ui_CaptureButton, capture_button_event_cb, LV_EVENT_CLICKED, NULL);

    lv_obj_t * btn_label = lv_label_create(ui_CaptureButton);
    lv_label_set_text(btn_label, "I Feel Something");
    lv_obj_set_style_text_color(btn_label, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_center(btn_label);
    
    // Page indicator
    ui_PageIndicator2 = lv_label_create(screen2);
    lv_label_set_text(ui_PageIndicator2, "○ ● ○");
    lv_obj_set_style_text_color(ui_PageIndicator2, lv_color_hex(0x888888), LV_PART_MAIN);
    lv_obj_set_style_text_font(ui_PageIndicator2, &lv_font_montserrat_12, LV_PART_MAIN);
    lv_obj_align(ui_PageIndicator2, LV_ALIGN_BOTTOM_MID, 0, -10);
}

// ==========================================
// UI SETUP - PAGE 3: TODAY SUMMARY
// ==========================================
void setupPage3() {
    screen3 = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(screen3, lv_color_hex(0x000000), LV_PART_MAIN);
    
    // Title
    ui_Page3Title = lv_label_create(screen3);
    lv_label_set_text(ui_Page3Title, "Today");
    lv_obj_set_style_text_font(ui_Page3Title, &lv_font_montserrat_16, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_Page3Title, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_align(ui_Page3Title, LV_ALIGN_TOP_MID, 0, 20);

    // Recording Time
    ui_RecordingTimeLabel = lv_label_create(screen3);
    lv_label_set_text(ui_RecordingTimeLabel, LV_SYMBOL_PLAY " Recording\n0h 0m");
    lv_obj_set_style_text_font(ui_RecordingTimeLabel, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_RecordingTimeLabel, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_set_style_text_align(ui_RecordingTimeLabel, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui_RecordingTimeLabel, LV_ALIGN_TOP_MID, 0, 60);

    // Events
    ui_EventsLabel = lv_label_create(screen3);
    lv_label_set_text(ui_EventsLabel, LV_SYMBOL_WARNING " Events\n0 captured");
    lv_obj_set_style_text_font(ui_EventsLabel, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_EventsLabel, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_set_style_text_align(ui_EventsLabel, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui_EventsLabel, LV_ALIGN_CENTER, 0, 0);

    // Last Sync
    ui_LastSyncLabel = lv_label_create(screen3);
    lv_label_set_text(ui_LastSyncLabel, LV_SYMBOL_REFRESH " Last Sync\nNot synced");
    lv_obj_set_style_text_font(ui_LastSyncLabel, &lv_font_montserrat_14, LV_PART_MAIN);
    lv_obj_set_style_text_color(ui_LastSyncLabel, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    lv_obj_set_style_text_align(ui_LastSyncLabel, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui_LastSyncLabel, LV_ALIGN_BOTTOM_MID, 0, -40);
    
    // Page indicator
    ui_PageIndicator3 = lv_label_create(screen3);
    lv_label_set_text(ui_PageIndicator3, "○ ○ ●");
    lv_obj_set_style_text_color(ui_PageIndicator3, lv_color_hex(0x888888), LV_PART_MAIN);
    lv_obj_set_style_text_font(ui_PageIndicator3, &lv_font_montserrat_12, LV_PART_MAIN);
    lv_obj_align(ui_PageIndicator3, LV_ALIGN_BOTTOM_MID, 0, -10);
}

// ==========================================
// SETUP
// ==========================================
void setup() {
  Serial.begin(115200);
  Serial.println("🚀 PulseWatch AI Starting...");
  Serial.printf("Wake count: %d\n", ++wakeCount);
  
  // 1. Init Hardware
  instance.begin();
  instance.setBrightness(SCREEN_BRIGHTNESS);
  instance.sensor.configAccelerometer();
  instance.sensor.enableAccelerometer();
  
  // 2. Setup power button event
  instance.onEvent([](DeviceEvent_t event, void *params, void * user_data) {
      if (instance.getPMUEventType(params) == PMU_EVENT_KEY_CLICKED) {
          powerButtonPressed = true;
          Serial.println("🔘 Power button pressed!");
      }
  }, POWER_EVENT, NULL);
  
  // 3. Init LVGL
  beginLvglHelper(instance);

  // 4. Create screens
  setupPage1();
  setupPage2();
  setupPage3();
  switchToScreen(0);

  // 5. Init BLE
  BLEDevice::init(BLE_DEVICE_NAME);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pAccelCharacteristic = pService->createCharacteristic(
                      CHAR_ACCEL_UUID,
                      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
                    );
  pAccelCharacteristic->addDescriptor(new BLE2902());

  pHRCharacteristic = pService->createCharacteristic(
                      CHAR_HEARTRATE_UUID,
                      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
                    );
  pHRCharacteristic->addDescriptor(new BLE2902());

  pService->start();
  
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(false);
  pAdvertising->setMinPreferred(0x0);
  BLEDevice::startAdvertising();
  
  Serial.println("✅ System Ready!");
  Serial.println("👆 Swipe left/right to navigate");
  Serial.println("🔘 Power button to sleep/wake");
  
  sessionStartTime = millis();
  lastActivityTime = millis();
  lastDataUpdateTime = millis();
}

// ==========================================
// LOOP
// ==========================================
void loop() {
  // Handle events
  instance.loop();
  lv_task_handler();
  
  // Handle touch gestures
  handleTouch();
  
  // Check for sleep timeout (30 seconds of inactivity)
  if (millis() - lastActivityTime > SLEEP_TIMEOUT_MS) {
    Serial.println("💤 Display sleep (BLE stays active)...");
    
    // Just dim the display, don't enter hardware sleep
    // This keeps BLE connection alive
    instance.setBrightness(0);
    
    // Wait for activity
    while (millis() - lastActivityTime > SLEEP_TIMEOUT_MS) {
      instance.loop();
      lv_task_handler();
      handleTouch();
      
      // Check for power button
      if (powerButtonPressed) {
        powerButtonPressed = false;
        lastActivityTime = millis();
        break;
      }
      
      // Still send BLE data even when display is off (medical monitoring!)
      if (millis() - lastDataUpdateTime > 100) {
        lastDataUpdateTime = millis();
        
        int16_t x, y, z;
        instance.sensor.getAccelerometer(x, y, z);
        
        simulatedHR += hrDirection;
        if(simulatedHR > 120) hrDirection = -1;
        if(simulatedHR < 60) hrDirection = 1;
        
        if (deviceConnected) {
          char accelStr[32];
          snprintf(accelStr, sizeof(accelStr), "%d,%d,%d", x, y, z);
          
          char hrStr[10];
          snprintf(hrStr, sizeof(hrStr), "%d", simulatedHR);

          pAccelCharacteristic->setValue((uint8_t*)accelStr, strlen(accelStr));
          pAccelCharacteristic->notify();

          pHRCharacteristic->setValue((uint8_t*)hrStr, strlen(hrStr));
          pHRCharacteristic->notify();
        }
      }
      
      delay(50);
    }
    
    // Woke up!
    Serial.println("⏰ Display woke up!");
    instance.setBrightness(SCREEN_BRIGHTNESS);
    lastActivityTime = millis();
  }

  // Update data every 100ms (battery-efficient rate)
  if (millis() - lastDataUpdateTime > 100) {
    lastDataUpdateTime = millis();

    // Get accelerometer
    int16_t x, y, z;
    instance.sensor.getAccelerometer(x, y, z);
    
    // Simulate HR
    simulatedHR += hrDirection;
    if(simulatedHR > 120) hrDirection = -1;
    if(simulatedHR < 60) hrDirection = 1;
    if(simulatedHR < minHR) minHR = simulatedHR;
    if(simulatedHR > maxHR) maxHR = simulatedHR;

    // Update UI for current screen only (saves CPU)
    if (currentScreen == 0) {
        lv_label_set_text(ui_TimeLabel, getFormattedTime().c_str());
        
        if (deviceConnected) {
          lv_obj_set_style_text_color(ui_ConnectionIcon, lv_color_hex(0x00FF00), LV_PART_MAIN);
        } else {
          lv_obj_set_style_text_color(ui_ConnectionIcon, lv_color_hex(0xFF0000), LV_PART_MAIN);
        }
        
        int battPercent = getBatteryPercent();
        lv_label_set_text_fmt(ui_BatteryLabel, LV_SYMBOL_BATTERY_3 " %d%%", battPercent);
        lv_label_set_text_fmt(ui_MainHRLabel, "HR: %d", simulatedHR);
        
    } else if (currentScreen == 1) {
        lv_label_set_text_fmt(ui_HRBigLabel, "%d BPM", simulatedHR);
        
        int avgHR = (minHR + maxHR) / 2;
        char rangeStr[64];
        snprintf(rangeStr, sizeof(rangeStr), "Today: %d-%d BPM\nAvg: %d BPM", minHR, maxHR, avgHR);
        lv_label_set_text(ui_HRRangeLabel, rangeStr);

        if (manualCaptureActive) {
          lv_obj_set_style_bg_color(ui_CaptureButton, lv_color_hex(0xE8A598), LV_PART_MAIN);
          manualCaptureActive = false;
        }
        
    } else if (currentScreen == 2) {
        String recordingTime = formatDuration(millis() - sessionStartTime);
        char recStr[64];
        snprintf(recStr, sizeof(recStr), LV_SYMBOL_PLAY " Recording\n%s", recordingTime.c_str());
        lv_label_set_text(ui_RecordingTimeLabel, recStr);

        char evtStr[64];
        snprintf(evtStr, sizeof(evtStr), LV_SYMBOL_WARNING " Events\n%d captured", eventsToday);
        lv_label_set_text(ui_EventsLabel, evtStr);

        String lastSync = getLastSyncText();
        char syncStr[64];
        snprintf(syncStr, sizeof(syncStr), LV_SYMBOL_REFRESH " Last Sync\n%s", lastSync.c_str());
        lv_label_set_text(ui_LastSyncLabel, syncStr);
    }

    // Send BLE data if connected
    if (deviceConnected) {
        char accelStr[32];
        snprintf(accelStr, sizeof(accelStr), "%d,%d,%d", x, y, z);
        
        char hrStr[10];
        snprintf(hrStr, sizeof(hrStr), "%d", simulatedHR);

        pAccelCharacteristic->setValue((uint8_t*)accelStr, strlen(accelStr));
        pAccelCharacteristic->notify();

        pHRCharacteristic->setValue((uint8_t*)hrStr, strlen(hrStr));
        pHRCharacteristic->notify();
    }
    
    // Handle BLE reconnection
    if (!deviceConnected && oldDeviceConnected) {
        delay(500);
        pServer->startAdvertising();
        oldDeviceConnected = deviceConnected;
    }
    if (deviceConnected && !oldDeviceConnected) {
        oldDeviceConnected = deviceConnected;
    }
  }
  
  delay(5);  // Small delay for system stability
}

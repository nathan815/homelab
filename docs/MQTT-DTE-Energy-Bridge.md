# Setting up DTE Energy Bridge in Home Assistant

First, enable the Mosquitto MQTT broker in Home Assistant.

Then, in Settings go to:
Add ons > Mosquitto broker > Customize textbox

Change `active: false` to `active: true`

Then, edit these 2 files:

config/configuration.yaml
```
mqtt:
    sensor:
        - name: "DTE Energy Bridge Summation"
          state_topic: "event/metering/summation/minute"
          unit_of_measurement: "W"
          value_template: "{{ value_json.value }}"

        - name: "DTE Energy Bridge Instant Energy Use"
          state_topic: "event/metering/instantaneous_demand"
          unit_of_measurement: "W"
          value_template: "{{ value_json.demand | int }}"

sensor:
    - platform: integration
      source: sensor.dte_energy_bridge #Name of the MQTT sensor#
      name: energy_used
      unit_prefix: k
      round: 2
```

share/mosquitto/mosquitto.conf
```
connection dte
address 192.168.0.171:2883
clientid homeassistant-1
try_private false
start_type automatic
topic # both 0
```

Go to Developer Tools > YAML > Check Configuration. Make sure it's OK.

Then click Restart.
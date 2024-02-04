from flask import Flask, render_template, request, redirect, url_for
from wakeonlan import send_magic_packet
import os
import subprocess

app = Flask(__name__)

computer_shortcuts = [
    {'name': 'Work Desktop', 'mac': 'A4:AE:11:1D:1A:BE', 'ip': '192.168.0.151'},
    {'name': 'Computer 2', 'mac': 'AA:BB:CC:DD:EE:FF', 'ip': '192.168.0.2'},
    # Add more computer shortcuts as needed
]

@app.route('/')
def index():
    return render_template('index.html.j2', computer_shortcuts=computer_shortcuts)

@app.route('/wakeonlan', methods=['POST'])
def wakeonlan():
    mac_address = request.form.get('mac')
    ip_address = request.form.get('ip')

    computer_info = {
        'name': request.form.get('name'),
        'ip': ip_address,
        'mac': mac_address
    }

    output = None
    error = None

    try:
        # Send magic packet
        ret = send_magic_packet(mac_address, ip_address=ip_address)
        print('send_magic_packet', ret)

        # Ping the provided IP address or resolve MAC to IP and ping
        if ip_address:
            output = subprocess.check_output(['ping', '-c', '4', ip_address]).decode()
        else:
            ip_address = subprocess.check_output(['arp', '-n', mac_address]).decode().split(' ')[0]
            output = subprocess.check_output(['ping', '-c', '4', ip_address]).decode()
    except subprocess.CalledProcessError as exc:
        print("Status : FAIL", exc.returncode, exc.output)
        error = f"Command '{exc.cmd}' failed with return code {exc.returncode}"
        output = f"Code: {exc.returncode}\n\n{exc.output.decode() if exc.output else ''}\n\n{exc.stderr.decode() if exc.stderr else ''}"
    except Exception as e:
        # If an exception occurs, store the exception message in ping_result
        error = "An error occurred. Please try again."
        output = str(e)

    # Render the wakeonlan_result template with the computer_info dictionary
    return render_template('wakeonlan_result.html.j2', computer_info=computer_info, output=output, error=error)

def main():
    print('Starting app')
    app.run(host='0.0.0.0', port=80)

if __name__ == "__main__":
    main()

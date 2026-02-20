#!/bin/bash

# Check if the systemd service file exists
if [ ! -f /etc/systemd/system/sing-box.service ]; then
    echo "Creating systemd service file at /etc/systemd/system/sing-box.service"
    echo "[Unit]" > /etc/systemd/system/sing-box.service
    echo "Description=Sing Box Service" >> /etc/systemd/system/sing-box.service
    echo "After=network.target" >> /etc/systemd/system/sing-box.service
    echo "" >> /etc/systemd/system/sing-box.service
    echo "[Service]" >> /etc/systemd/system/sing-box.service
    echo "ExecStart=/usr/local/bin/sing-box" >> /etc/systemd/system/sing-box.service
    echo "Restart=on-failure" >> /etc/systemd/system/sing-box.service
    echo "" >> /etc/systemd/system/sing-box.service
    echo "[Install]" >> /etc/systemd/system/sing-box.service
    echo "WantedBy=multi-user.target" >> /etc/systemd/system/sing-box.service
fi

# Further update process... (your existing update logic here)
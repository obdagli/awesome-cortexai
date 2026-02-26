# HEARTBEAT.md

- [ ] Run: bash /home/brk/tools/update-status-board.sh
- [ ] If active workers exist, run: python3 /home/brk/tools/adaptive-timeout.py check
- [ ] If active workers exist with runtime > 30min, run: python3 /home/brk/tools/worker-reaper.py
- [ ] Check disk usage: if /home > 80%, alert (df -h /home | awk 'NR==2{print $5}')
- [ ] Check openclaw cron list: if any cron in "error" state for >2 hours, alert

# oogi-vpn-updater — Install Guide

Each step is labelled with where you need to act:
- **[Alibaba Console]** — browser, alibaba cloud console
- **[China ECS]** — SSH session to `120.79.157.95`
- **[MikroTik]** — Winbox terminal or SSH to the router
- **[Your machine]** — run locally (generates a value you'll paste elsewhere)

---

## Step 1 — Create RAM User **[Alibaba Console]**

1. Go to **RAM → Users → Create User**
2. Set:
   - Display name: `oogi-vpn-updater`
   - Access mode: **OpenAPI Access only** (no console login)
3. Click **OK**, then on the next screen click **Add Permissions**
4. Choose **Custom Policy → Create Policy**, paste this JSON:

```json
{
  "Version": "1",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "vpc:CreateCustomerGateway",
      "vpc:DeleteCustomerGateway",
      "vpc:DescribeCustomerGateways",
      "vpc:ModifyTunnelAttribute"
    ],
    "Resource": "*"
  }]
}
```

5. Attach the policy to `oogi-vpn-updater`
6. Go to **RAM → Users → oogi-vpn-updater → Security → Create AccessKey**
7. **Save the AccessKey ID and Secret** — you will need them in Step 4. They are only shown once.

---

## Step 2 — Open Port 8444 **[Alibaba Console]**

1. Go to **ECS → Instances → China ECS → Security Groups → Manage Rules → Inbound**
2. Add rule:

| Priority | Action | Protocol | Port | Source |
|----------|--------|----------|------|--------|
| 1 | Allow | TCP | 8444 | `0.0.0.0/0` |

---

## Step 3 — Generate Shared Secret **[Your machine]**

Run this once and keep the output — you'll need it in Steps 4 and 6:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

---

## Step 4 — Deploy the Service **[China ECS]**

SSH to the China ECS (`ssh user@120.79.157.95`), then run:

```bash
# TLS cert (self-signed — no DNS needed)
sudo mkdir -p /etc/nginx/ssl/vpn-updater
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/nginx/ssl/vpn-updater/privkey.pem \
    -out    /etc/nginx/ssl/vpn-updater/fullchain.pem \
    -subj "/CN=oogi-vpn-updater"
sudo chmod 600 /etc/nginx/ssl/vpn-updater/privkey.pem

# Service user
sudo useradd -r -s /usr/sbin/nologin vpn-updater

# Deploy app files (copy from this repo)
sudo mkdir -p /opt/oogi-vpn-updater
sudo cp app.py alibaba_client.py requirements.txt /opt/oogi-vpn-updater/
sudo chown -R vpn-updater:vpn-updater /opt/oogi-vpn-updater

# Python virtualenv (install python3-venv first if missing)
sudo apt install python3.12-venv -y
sudo -u vpn-updater python3 -m venv /opt/oogi-vpn-updater/venv
# Always use Alibaba's PyPI mirror on China ECS — PyPI direct is slow/unreliable from China
sudo -H -u vpn-updater /opt/oogi-vpn-updater/venv/bin/pip install --no-cache-dir \
    -i https://mirrors.aliyun.com/pypi/simple/ \
    flask==3.0.3 gunicorn==22.0.0 \
    alibabacloud-vpc20160428 alibabacloud-tea-openapi alibabacloud-tea-util

# Credentials file — YOU MUST EDIT THIS with real values
sudo mkdir -p /etc/oogi-vpn-updater
sudo cp credentials.example /etc/oogi-vpn-updater/credentials
sudo chmod 0600 /etc/oogi-vpn-updater/credentials
sudo chown vpn-updater:vpn-updater /etc/oogi-vpn-updater/credentials
```

Now fill in the credentials file:

```bash
sudo nano /etc/oogi-vpn-updater/credentials
```

Set these four values (the rest are already correct):
- `ALIYUN_ACCESS_KEY_ID` — from Step 1
- `ALIYUN_ACCESS_KEY_SECRET` — from Step 1
- `OOGI_SHARED_SECRET` — from Step 3
- `ALIYUN_REGION` — already set to `cn-shenzhen`, change only if your VPN gateway is in a different region

Then start the service:

```bash
sudo cp oogi-vpn-updater.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now oogi-vpn-updater

# Verify
sudo systemctl status oogi-vpn-updater
curl http://127.0.0.1:5000/healthz
# Expected: {"status":"ok"}
```

---

## Step 5 — Configure nginx **[China ECS]**

```bash
sudo cp nginx-vpn-updater.conf /etc/nginx/sites-available/vpn-updater
sudo ln -s /etc/nginx/sites-available/vpn-updater /etc/nginx/sites-enabled/vpn-updater

# Deploy the updated main nginx.conf from the repo
# (the only change is removing the vpn-updater SNI entry that's no longer needed)
sudo cp /path/to/repo/china-ecs/nginx.conf /etc/nginx/nginx.conf

sudo nginx -t && sudo systemctl reload nginx
```

---

## Step 6 — Configure MikroTik **[MikroTik]**

1. Copy `mikrotik/configure-ip-monitor.rsc` and `mikrotik/check-public-ip.rsc` to the MikroTik (via Winbox → Files)

2. Run the installer:
   ```
   /import file=configure-ip-monitor.rsc
   ```

3. Open the monitor script for editing:
   ```
   /system script edit check-public-ip source
   ```
   Paste the full contents of `check-public-ip.rsc` into the editor.

4. In the script, find this line and replace `REPLACE_WITH_SHARED_SECRET` with the secret from Step 3:
   ```
   :local sharedSecret "REPLACE_WITH_SHARED_SECRET"
   ```

5. Save and exit (`Ctrl+X` in the terminal editor, or close the Winbox editor).

---

## Step 7 — Smoke Test

**From China ECS** — tests the service directly (replace `<secret>` with your value from Step 3):

```bash
curl -sk -X POST https://120.79.157.95:8444/update-vpn-ip \
    -H "Authorization: Bearer <secret>" \
    -H "Content-Type: application/json" \
    -d '{"newIp":"223.73.2.155","timestamp":'"$(date +%s)"'}'
# Expected: {"status":"ok","newCgwId":"...","tunnelId":"tun-wz9gip67wfcp1ro8x3ffu"}
```

**From MikroTik** — triggers the full end-to-end flow:

```
/system script run check-public-ip
/log print where topics~"oogi-vpn"
```

If the IP hasn't changed since last run, force a test by temporarily clearing the stored IP:
```
/system script set [find name=oogi-last-public-ip] source=""
/system script run check-public-ip
```

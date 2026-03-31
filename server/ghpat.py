import time
import jwt # pip install PyJWT cryptography
import requests
import os

APP_ID = os.environ["GH_APP_ID"]
PEM_FILE_PATH = os.environ["GH_APP_PEM_FILE_PATH"]

private_key_contents = open(PEM_FILE_PATH, "r").read()

payload = {
    "iat": int(time.time()),
    "exp": int(time.time()) + (10 * 30), # 30 mins
    "iss": APP_ID,
}

encoded_jwt = jwt.encode(payload, private_key_contents, algorithm="RS256")

headers = {
    "Authorization": f"Bearer {encoded_jwt}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2026-03-10"
}

osi_url = "https://api.github.com/app/installations"
response = requests.get(osi_url, headers=headers)
resp_dict = response.json()

INST_ID = resp_dict[0]['id']


response = requests.post(f"https://api.github.com/app/installations/{INST_ID}/access_tokens", headers=headers)
print(response.json()['token'])

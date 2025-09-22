Nice-to-have for your mod

Document the requirement in your README and ContentDB page (e.g., “Add secure.http_mods = eduquest to your config”). Many HTTP-using mods do this.
content.luanti.org
+1

Provide a small self-test command (e.g., /eduquest_http_probe) that tries a GET and reports “granted/not granted”, so users know they set it correctly. The HTTP API docs show the expected fields (fetch, fetch_async, etc.).
Luanti Documentation

If you want, I can drop a tiny :probe chatcommand into your mod that checks permission and prints exactly which config file/key the user should edit based on singleplayer vs server.

# Security

Never attach account profiles, auth caches, browser-login URLs, Keychain contents, or raw CLI output to an issue. The account manager intentionally exposes only connection metadata and quota fields.

Report a suspected vulnerability through GitHub's private vulnerability reporting for this repository when available. Avoid public proof-of-concept files containing credentials. For a vendor authentication problem, report it to that vendor.

Account storage is local and owner-only. The app never changes the user's default CLI login. Browser sign-in and token refresh are owned by the official tools. Automatic selection does not change provider limits or alter running sessions.

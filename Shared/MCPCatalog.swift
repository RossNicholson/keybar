import Foundation

/// What the MCP server tells AI apps: its instructions and its tools. In
/// Shared so the app's tests can check them.
enum MCPCatalog {
    static let instructions = """
    KeyBar keeps the user's API keys and tokens (Claude, Cloudflare, GitHub and others) in the macOS Keychain. \
    Before asking the user to paste a key, or reading one from a .env file, call list_secrets to see what's stored. \
    To run a command that needs a key, call run_with_secrets with the key names: each one is set as an environment \
    variable of that name, so refer to it as "$NAME" in the command. Never put a key's value in a command, and never \
    try to print, echo or save a key. Output comes back with any copy of a key replaced by [REDACTED]. \
    Don't run `keybar run` yourself: it's for the user's own terminal and doesn't hide keys. A .env line like \
    NAME=keybar:STORED_NAME means the key is in KeyBar as STORED_NAME. A key that's a file (marked "file" in \
    list_secrets) is set as the path to a private copy of it, for tools that want a key file. If a key you need \
    isn't stored, call request_secret: KeyBar asks the user to add it, and you never see it. To put a key into a \
    GitHub repo's Actions secrets or a Cloudflare Worker's or Pages project's secrets, call send_secret rather \
    than piping it into gh or wrangler yourself. A key marked "through KeyBar's proxy" is set to a placeholder: \
    SDKs read the base URL variable named there (e.g. ANTHROPIC_BASE_URL) and work as normal; for curl, call \
    "$ANTHROPIC_BASE_URL/v1/messages" instead of the service's own address. A project's .keybar file lists the \
    keys it uses; others are hidden there. If a commit is stopped by KeyBar's commit guard, a stored key's value \
    is in the changes: replace it with a reference to the environment variable, never commit it. \
    KeyBar also keeps website logins (a username and password), listed in their own section by list_secrets with \
    their websites. You never see a login's username or password. To sign in to a site: open its login page in the \
    browser and call fill_password with the login's name: KeyBar types the username and password into the page \
    and presses Return to sign in, then tells you what happened. Don't type the username yourself. If the site \
    asks for the username on one page and the password on the next, call fill_password on each page. KeyBar only \
    fills https pages on the login's websites or their subdomains. If the user has turned on logins in commands \
    (list_secrets says so), run_with_secrets can use a login too: it's set as $NAME_USERNAME and $NAME_PASSWORD. \
    Never ask the user to type or paste a password into the chat; if one isn't stored, call request_secret with \
    type "password" and the website.
    """

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        [
            "name": "list_secrets",
            "title": "List stored keys and passwords",
            "description": """
            Lists the API keys and tokens stored in KeyBar: each one's name (also the environment variable it's \
            set as), the service it's for and what kind of credential it is. Website logins are listed in their \
            own section, with their websites, for fill_password. Values and usernames are never shown. Call this \
            before asking the user for a key or a password.
            """,
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "run_with_secrets",
            "title": "Run a command with stored keys",
            "description": """
            Runs a shell command with the named KeyBar keys set as environment variables, e.g. secretNames \
            ["CLOUDFLARE_API_TOKEN"] and command "curl -H \\"Authorization: Bearer $CLOUDFLARE_API_TOKEN\\" \
            https://api.cloudflare.com/client/v4/user/tokens/verify". Refer to keys only as "$NAME"; a command \
            containing a key's actual value is refused. Returns the exit code, stdout and stderr, with any copy \
            of a key replaced by [REDACTED]. Runs in the project folder unless cwd is given. Keys may be limited \
            to certain project folders. A website login can be used only if the user allowed logins in commands \
            (list_secrets says so): it's set as $NAME_USERNAME and $NAME_PASSWORD, never shown to you.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command to run (zsh)."],
                    "secretNames": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Names of the keys to set as environment variables.",
                    ],
                    "cwd": ["type": "string", "description": "Folder to run in. Defaults to the project folder."],
                    "timeoutSeconds": [
                        "type": "number",
                        "description": "Stop the command after this many seconds (default 120, at most 600).",
                    ],
                ],
                "required": ["command", "secretNames"],
                "additionalProperties": false,
            ],
            "annotations": ["destructiveHint": true, "openWorldHint": true],
        ],
        [
            "name": "fill_password",
            "title": "Sign in with a website login",
            "description": """
            Signs in on the login page open in Safari or a Chromium browser (Chrome, Arc, Brave, Edge, Vivaldi): \
            KeyBar types the stored username and password into the page itself and presses Return. First open \
            the login page; don't type the username yourself. If the site asks for the username on one page and \
            the password on the next, call this on each page. KeyBar only fills https pages on the login's \
            websites (or their subdomains), may ask the user with Touch ID, and replies with what it did and \
            whether the page moved on. You never see the username or password. If a page has several login \
            forms, click into the right one first.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The stored login's name (see list_secrets), e.g. LOGIN_LIVERPOOLFC."],
                    "site": [
                        "type": "string",
                        "description": "Optional: the site to fill, when the password has several websites open at once, e.g. accounts.liverpoolfc.com.",
                    ],
                ],
                "required": ["name"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": true],
        ],
        [
            "name": "request_secret",
            "title": "Ask the user to add a key or password",
            "description": """
            Asks the user to add a key or website password KeyBar doesn't have yet: KeyBar opens its Add window \
            with the details filled in and your reason shown, and the user pastes (or makes up) the value there. \
            Waits up to 5 minutes for them. You never see the value; once it's added, use a key with \
            run_with_secrets and a login with fill_password. For a key, give its name. For a password, give \
            type "password" and the website (and the username if you know it); the name is optional. Use this \
            instead of asking the user to paste a key or password into the chat.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The name to store it as, e.g. CLOUDFLARE_API_TOKEN (also its environment variable). Optional for a password."],
                    "reason": ["type": "string", "description": "One short line for the user: what it's for and where to get it."],
                    "type": ["type": "string", "enum": SecretType.allCases.map(\.rawValue), "description": "apiKey (the default) or password."],
                    "website": ["type": "string", "description": "For a password: the site it's for, e.g. liverpoolfc.com or the login page's address."],
                    "username": ["type": "string", "description": "For a password: the username or email, if known."],
                ],
                "required": ["reason"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": "send_secret",
            "title": "Send a key to GitHub or Cloudflare",
            "description": """
            Sends one stored key to a GitHub repository's Actions secrets (with gh), or a Cloudflare Worker's or \
            Pages project's secrets (with wrangler), so a deploy can use it. KeyBar asks the user with Touch ID \
            every time and sends it itself; the value never passes through you. Replaces a secret of the same name \
            there. Website logins are never sent.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "secretName": ["type": "string", "description": "The stored key to send (see list_secrets)."],
                    "destination": [
                        "type": "string", "enum": Destination.Kind.allCases.map(\.rawValue),
                        "description": "githubActions, cloudflareWorker or cloudflarePages.",
                    ],
                    "target": ["type": "string", "description": "owner/repo for GitHub, else the Worker's or Pages project's name."],
                    "nameThere": ["type": "string", "description": "The secret's name there. Defaults to secretName."],
                ],
                "required": ["secretName", "destination", "target"],
                "additionalProperties": false,
            ],
            "annotations": ["destructiveHint": true, "openWorldHint": true],
        ],
    ]

    static var toolNames: [String] { tools.compactMap { $0["name"] as? String } }
}

# Capability: webmcp

Pages can register tools through WebMCP (`navigator.modelContext`). `fetchTools()` →
`{ tools: [{ name, description, inputSchema }], invoke(name, args) }`.

A page's tools act with the user's session on that site. Treat invoking one like the
equivalent UI action: confirm first when it would send, buy, delete or share.

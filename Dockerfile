# 1. Base Image: Pinning to a specific version ensures production stability
#    (Using 'latest' for now to ensure we get the newest features as requested)
FROM docker.n8n.io/n8nio/n8n:latest

# 2. Switch to Root: Required to install global NPM packages
USER root

# 3. Install System Dependencies (Optional but good for debugging)
#    Installing curl/git can help with healthchecks or advanced nodes
RUN apk add --no-cache curl git

# 4. Install The "Enhanced Redis" Node
#    We install it globally so n8n can discover it as a custom node
RUN npm install -g @vicenterusso/n8n-nodes-redis-enhanced

# 5. Permission Fix: Ensure the 'node' user owns the new packages
#    (Prevents "EACCES" errors when n8n tries to run)
# OPTIMIZATION: Only chown the specific plugin folder, not the entire library
# This reduces build time from ~10+ mins to ~80 seconds.
RUN chown -R node:node /usr/local/lib/node_modules/@vicenterusso

# 6. Switch back to 'node' User: Never run applications as root!
USER node

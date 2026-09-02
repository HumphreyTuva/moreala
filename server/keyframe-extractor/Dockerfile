# Deploy target: Cloud Run job, Fly.io, Railway, or any container host
# that lets you set env vars and doesn't kill long-running processes
# early. Needs: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, R2_ACCOUNT_ID,
# R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME.

FROM node:20-slim

RUN apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json .
RUN npm install
COPY index.js .

# Example invocation once deployed:
#   docker run --env-file .env moreala-keyframe-extractor node index.js <modelId> <rawVideoObjectKey>
CMD ["node", "index.js"]

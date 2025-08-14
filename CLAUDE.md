# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a self-hosted Supabase installation using Docker Compose. It includes the full Supabase stack: PostgreSQL database, authentication, storage, edge functions, and analytics.

## Essential Commands

### Starting and Stopping Services

```bash
# Start all services
docker compose up -d

# Start with S3 storage backend (MinIO)
docker compose -f docker-compose.yml -f docker-compose.s3.yml up -d

# Stop all services
docker compose down

# Reset everything (DESTRUCTIVE - removes all data)
./reset.sh
```

### Database Access

```bash
# Connect to PostgreSQL
docker exec -it supabase-db psql -U postgres

# Database is accessible at localhost:54322
# Default credentials in .env:
#   User: postgres
#   Password: ${POSTGRES_PASSWORD}
```

### Monitoring Services

```bash
# View running containers
docker compose ps

# View logs for specific service
docker compose logs [service-name]  # e.g., db, auth, storage

# Check service health
docker compose ps --format json | jq '.[].Health'
```

## Architecture

### Core Services

- **Kong** (port 8000): API gateway that routes requests to internal services
- **PostgreSQL** (port 54322): Main database with multiple schemas for different services
- **Auth** (GoTrue): Handles user authentication and JWT tokens
- **Storage**: File storage with optional S3/MinIO backend
- **Realtime**: WebSocket server for real-time subscriptions
- **Functions**: Deno-based edge functions runtime
- **Analytics** (Logflare): Collects and stores logs/metrics

### Service Dependencies

Services start in dependency order:
1. Vector (logging) → Database → Analytics
2. Analytics → Kong, Auth, Rest, Meta, Functions
3. Database → Realtime, Storage, Pooler

### Configuration

- Main configuration: `.env` file (contains secrets and service settings)
- Kong routing: `volumes/api/kong.yml`
- Database initialization: `volumes/db/*.sql` files
- Functions: `volumes/functions/` directory

## Key URLs

- **Supabase API**: http://localhost:8000
- **Studio Dashboard**: http://localhost:3000
- **MinIO Console** (if using S3): http://localhost:9001
- **Analytics**: http://localhost:4000

## Important Security Notes

The `.env` file contains default development credentials that MUST be changed before production use:
- `POSTGRES_PASSWORD`
- `JWT_SECRET`
- `ANON_KEY`
- `SERVICE_ROLE_KEY`
- `DASHBOARD_USERNAME/PASSWORD`
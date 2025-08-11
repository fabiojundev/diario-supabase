

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "auth";


ALTER SCHEMA "auth" OWNER TO "supabase_admin";


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE SCHEMA IF NOT EXISTS "storage";


ALTER SCHEMA "storage" OWNER TO "supabase_admin";


CREATE TYPE "auth"."aal_level" AS ENUM (
    'aal1',
    'aal2',
    'aal3'
);


ALTER TYPE "auth"."aal_level" OWNER TO "supabase_auth_admin";


CREATE TYPE "auth"."code_challenge_method" AS ENUM (
    's256',
    'plain'
);


ALTER TYPE "auth"."code_challenge_method" OWNER TO "supabase_auth_admin";


CREATE TYPE "auth"."factor_status" AS ENUM (
    'unverified',
    'verified'
);


ALTER TYPE "auth"."factor_status" OWNER TO "supabase_auth_admin";


CREATE TYPE "auth"."factor_type" AS ENUM (
    'totp',
    'webauthn',
    'phone'
);


ALTER TYPE "auth"."factor_type" OWNER TO "supabase_auth_admin";


CREATE TYPE "auth"."one_time_token_type" AS ENUM (
    'confirmation_token',
    'reauthentication_token',
    'recovery_token',
    'email_change_token_new',
    'email_change_token_current',
    'phone_change_token'
);


ALTER TYPE "auth"."one_time_token_type" OWNER TO "supabase_auth_admin";


CREATE OR REPLACE FUNCTION "auth"."email"() RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select 
  coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$$;


ALTER FUNCTION "auth"."email"() OWNER TO "supabase_auth_admin";


COMMENT ON FUNCTION "auth"."email"() IS 'Deprecated. Use auth.jwt() -> ''email'' instead.';



CREATE OR REPLACE FUNCTION "auth"."jwt"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  select 
    coalesce(
        nullif(current_setting('request.jwt.claim', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb
$$;


ALTER FUNCTION "auth"."jwt"() OWNER TO "supabase_auth_admin";


CREATE OR REPLACE FUNCTION "auth"."role"() RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select 
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;


ALTER FUNCTION "auth"."role"() OWNER TO "supabase_auth_admin";


COMMENT ON FUNCTION "auth"."role"() IS 'Deprecated. Use auth.jwt() -> ''role'' instead.';



CREATE OR REPLACE FUNCTION "auth"."uid"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    AS $$
  select 
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;


ALTER FUNCTION "auth"."uid"() OWNER TO "supabase_auth_admin";


COMMENT ON FUNCTION "auth"."uid"() IS 'Deprecated. Use auth.jwt() -> ''sub'' instead.';



CREATE PROCEDURE "public"."archive_user_views"()
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    INSERT INTO user_views_archive
    SELECT * FROM user_views WHERE viewed_at < NOW() - INTERVAL '30 days';

    DELETE FROM user_views WHERE viewed_at < NOW() - INTERVAL '30 days';
END;
$$;


ALTER PROCEDURE "public"."archive_user_views"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."count_likes"("user_id" integer) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN (
        SELECT count(e.*)
        FROM events e
        WHERE e.object_id IN (
            SELECT w.id
            FROM weeks w
            WHERE w.user_id = count_likes.user_id
            UNION
            SELECT q.id
            FROM questions q
            WHERE q.user_id = count_likes.user_id
        )
        AND e.event_type IN ('liked', 'liked_question')
    );
END;
$$;


ALTER FUNCTION "public"."count_likes"("user_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_user_profile"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  profile_id integer;
  username text;
  email text;
  avatar_xy jsonb;
  avatar_url text;
BEGIN
  -- Extract username, email and avatar_xy from auth.users metadata
  username := NEW.raw_user_meta_data ->> 'username';
  email := NEW.email;
  avatar_xy := NEW.raw_user_meta_data -> 'avatar_xy';
  avatar_url := NEW.raw_user_meta_data ->> 'avatar_url';

  -- Insert new profile or fetch existing one to avoid duplicate-key errors
  INSERT INTO public.profiles (uid, username, email, avatar_xy, avatar_url, created_at, updated_at)
  VALUES (NEW.id, username, email, avatar_xy, avatar_url, NOW(), NOW())
  RETURNING id INTO profile_id;

  -- Update the auth.users.metadata with the profile.id
  UPDATE auth.users au
  SET raw_user_meta_data = jsonb_set(
    au.raw_user_meta_data,
    '{user_id}',
    to_jsonb(profile_id)
  )
  WHERE au.id = NEW.id;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."create_user_profile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fetch_user_feed"("user_id" integer, "seen_post_ids" integer[] DEFAULT NULL::integer[], "page_number" integer DEFAULT 1, "page_size" integer DEFAULT 50, "include_stories" boolean DEFAULT false, "only_stories" boolean DEFAULT false) RETURNS TABLE("posts" "jsonb"[], "events" "jsonb"[], "comments" "jsonb"[], "profiles" "jsonb"[])
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    user_feed_qty INT := 3;
BEGIN
    -- Mark seen posts for authenticated users only
    IF seen_post_ids IS NOT NULL AND fetch_user_feed.user_id > 0 THEN
        CALL mark_posts_seen(fetch_user_feed.user_id, seen_post_ids);
    END IF;

    -- Unified feed: combine personal and recommended
    RETURN QUERY
    WITH followed AS (
        SELECT post_id FROM user_feed uv
        WHERE uv.user_id = fetch_user_feed.user_id
          AND post_id NOT IN (
            SELECT post_id FROM user_views uv2 WHERE uv2.user_id = fetch_user_feed.user_id
          )
          AND (NOT fetch_user_feed.include_stories OR uv.post_type != 'story')
          AND (NOT fetch_user_feed.only_stories OR uv.post_type = 'story')
        ORDER BY created_at DESC
        LIMIT user_feed_qty
    ),
    recommended AS (
        SELECT post_id FROM recommended_feed
        WHERE (
            fetch_user_feed.user_id > 0
            AND post_id NOT IN (
                SELECT post_id FROM user_views uv3 WHERE uv3.user_id = fetch_user_feed.user_id
            )
        )
        OR fetch_user_feed.user_id = 0
        ORDER BY score DESC
        LIMIT CASE
            WHEN fetch_user_feed.user_id > 0 THEN page_size - user_feed_qty
            ELSE page_size
        END
        OFFSET CASE
            WHEN fetch_user_feed.user_id = 0 THEN (page_number - 1) * page_size
            ELSE 0
        END
    ),
    union_posts AS (
        SELECT post_id FROM followed
        UNION ALL
        SELECT post_id FROM recommended
    ),
    selected_posts AS (
        SELECT post_id FROM union_posts
        ORDER BY random()
        LIMIT page_size
    ),
    followed_posts AS (
        SELECT * FROM posts WHERE id IN (SELECT post_id FROM selected_posts)
    ),
    realated_post AS (
        SELECT * FROM posts
        WHERE posts.id IN (
            SELECT followed_posts.parent_id FROM followed_posts
        )
    ),
    followed_comments AS (
        SELECT * FROM comments WHERE comments.post_id IN (SELECT id FROM followed_posts)
    ),
    followed_events AS (
        SELECT * FROM events
        WHERE object_id IN (SELECT id FROM followed_posts)
           OR comment_id IN (SELECT id FROM followed_comments)
    ),
    related_profiles AS (
        SELECT * FROM profiles p WHERE p.id IN (
            SELECT followed_comments.user_id FROM followed_comments
            UNION
            SELECT fp.user_id FROM followed_posts fp
            UNION
            SELECT followed_events.user_id FROM followed_events
        )
    )

    SELECT
        ARRAY(
            SELECT to_jsonb(d) FROM followed_posts d
            UNION
            SELECT to_jsonb(r) FROM realated_post r
        ) AS posts,
        ARRAY(SELECT to_jsonb(e) FROM followed_events e) AS events,
        ARRAY(SELECT to_jsonb(c) FROM followed_comments c) AS comments,
        ARRAY(SELECT to_jsonb(rp) FROM related_profiles rp) AS profiles;
END;
$$;


ALTER FUNCTION "public"."fetch_user_feed"("user_id" integer, "seen_post_ids" integer[], "page_number" integer, "page_size" integer, "include_stories" boolean, "only_stories" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_legacy_user_id"() RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN (
    SELECT ((u.raw_user_meta_data ->> 'user_id'::text))::bigint AS int8
    FROM auth.users u
    WHERE (u.id = auth.uid()));
END;
$$;


ALTER FUNCTION "public"."get_legacy_user_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_post"("post_id" integer DEFAULT NULL::integer, "name" "text" DEFAULT NULL::"text") RETURNS TABLE("posts" "jsonb"[], "events" "jsonb"[], "comments" "jsonb"[], "profiles" "jsonb"[])
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  WITH searched_post AS (
    SELECT * FROM posts p
        WHERE (get_post.name IS NOT NULL AND LOWER(p.name) = LOWER(get_post.name))
            OR (get_post.post_id IS NOT NULL AND p.id = get_post.post_id) 
        LIMIT 1
  ),
  realated_post AS (
      SELECT * FROM posts 
      WHERE posts.parent_id IN (
        SELECT searched_post.id FROM searched_post 
        LIMIT 1
      ) OR (posts.id IN (
        SELECT searched_post.parent_id FROM searched_post 
        WHERE searched_post.parent_id > 0
      ))
  ),
  post_comments AS (
    SELECT * FROM comments WHERE comments.post_id IN (
        SELECT id FROM searched_post
        UNION
        SELECT id FROM realated_post
    )
  ),
  post_events AS (
    SELECT * FROM events 
    WHERE object_id IN (
        SELECT id FROM searched_post
        UNION
        SELECT id FROM realated_post
    ) 
    OR comment_id IN (SELECT id FROM post_comments)
  ),
  related_profiles AS (
    SELECT * FROM profiles p WHERE p.id IN (
        SELECT searched_post.user_id FROM searched_post
        UNION
        SELECT post_comments.user_id FROM post_comments
        UNION
        SELECT post_events.user_id FROM post_events
    )
  )

  SELECT
    ARRAY(
        SELECT to_jsonb(d) FROM searched_post d 
        UNION 
        SELECT to_jsonb(r) FROM realated_post r
    ) AS post,
    ARRAY(SELECT to_jsonb(e) FROM post_events e) AS events,
    ARRAY(SELECT to_jsonb(c) FROM post_comments c) AS comments,
    ARRAY(SELECT to_jsonb(rp) FROM related_profiles rp) AS profiles;
END;
$$;


ALTER FUNCTION "public"."get_post"("post_id" integer, "name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_post_by_name"("name" "text") RETURNS TABLE("posts" "jsonb"[], "events" "jsonb"[], "comments" "jsonb"[], "profiles" "jsonb"[])
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  WITH searched_post AS (
    SELECT * FROM posts WHERE posts.name = get_post_by_name.name LIMIT 1
  ),
  post_comments AS (
    SELECT * FROM comments WHERE comments.post_id IN (SELECT id FROM searched_post)
  ),
  post_events AS (
    SELECT * FROM events 
    WHERE object_id IN (SELECT id FROM searched_post) 
       OR object_parent_id IN (SELECT id FROM searched_post) 
       OR comment_id IN (SELECT id FROM post_comments)
  ),
  related_profiles AS (
    SELECT * FROM profiles p WHERE p.id IN (
        SELECT post_comments.user_id FROM post_comments
        UNION
        SELECT post_events.user_id FROM post_events
    )
  )

  SELECT
    ARRAY(SELECT to_jsonb(d) FROM searched_post d LIMIT 1) AS post,
    ARRAY(SELECT to_jsonb(e) FROM post_events e) AS events,
    ARRAY(SELECT to_jsonb(c) FROM post_comments c) AS comments,
    ARRAY(SELECT to_jsonb(rp) FROM related_profiles rp) AS profiles;
END;
$$;


ALTER FUNCTION "public"."get_post_by_name"("name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_data"("username" "text" DEFAULT NULL::"text", "user_id" integer DEFAULT NULL::integer) RETURNS TABLE("profiles" "jsonb"[], "follows" "jsonb"[], "followers" "jsonb"[], "posts" "jsonb"[], "events" "jsonb"[], "comments" "jsonb"[])
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  WITH user_profiles AS (
    SELECT * FROM profiles p 
    WHERE (get_user_data.username IS NOT NULL AND LOWER(p.username) = LOWER(get_user_data.username))
        OR (get_user_data.user_id IS NOT NULL AND p.id = get_user_data.user_id) 
  ),
  user_follows AS (
    SELECT * FROM follows WHERE follows.follower_id IN (SELECT id FROM user_profiles)
  ),
  user_followers AS (
    SELECT * FROM follows WHERE follows.followee_id IN (SELECT id FROM user_profiles)
  ),
  user_posts AS (
    SELECT * FROM posts WHERE posts.user_id IN (SELECT id FROM user_profiles)
  ),
  user_comments AS (
    SELECT * FROM comments 
    WHERE post_id IN (SELECT id FROM user_posts)
  ),
  user_events AS (
    SELECT * FROM events 
    WHERE object_id IN (SELECT id FROM user_posts) 
       OR comment_id IN (SELECT id FROM user_comments)
  ),
  related_users AS (
    SELECT * FROM profiles p WHERE p.id IN (
        SELECT user_comments.user_id FROM user_comments
        UNION
        SELECT user_events.user_id FROM user_events
        UNION 
        SELECT user_follows.followee_id FROM user_follows
        UNION 
        SELECT user_followers.follower_id FROM user_followers
    )
  )
  SELECT
    ARRAY(SELECT to_jsonb(p) FROM user_profiles p UNION SELECT to_jsonb(rp) FROM related_users rp) AS profiles,
    ARRAY(SELECT to_jsonb(f) FROM user_follows f order by f.created_at desc) AS follows,
    ARRAY(SELECT to_jsonb(ff) FROM user_followers ff order by ff.created_at desc) AS followers,
    ARRAY(SELECT to_jsonb(d) FROM user_posts d order by d.id desc) AS posts,
    ARRAY(SELECT to_jsonb(e) FROM user_events e order by e.id desc) AS events,
    ARRAY(SELECT to_jsonb(c) FROM user_comments c order by c.id desc) AS comments;
END;
$$;


ALTER FUNCTION "public"."get_user_data"("username" "text", "user_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_feed"("user_id" integer, "seen_post_ids" integer[] DEFAULT NULL::integer[]) RETURNS TABLE("posts" "jsonb"[], "events" "jsonb"[], "comments" "jsonb"[], "profiles" "jsonb"[])
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Mark provided posts as seen
    IF seen_post_ids IS NOT NULL THEN
        PERFORM set_posts_seen(seen_post_ids);
    END IF;

  RETURN QUERY
  WITH followed_posts AS (
    SELECT * FROM posts WHERE posts.id IN (SELECT f.post_id 
        FROM feeds f WHERE f.user_id = get_user_feed.user_id
        AND seen = FALSE 
    )
  ),
  realated_post AS (
      SELECT * FROM posts 
      WHERE posts.id IN (
        SELECT followed_posts.parent_id FROM followed_posts 
      )
  ),
  followed_comments AS (
    SELECT * FROM comments WHERE comments.post_id IN (SELECT id FROM followed_posts)
  ),
  followed_events AS (
    SELECT * FROM events 
    WHERE object_id IN (SELECT id FROM followed_posts) 
       OR comment_id IN (SELECT id FROM followed_comments)
  ),
  related_profiles AS (
    SELECT * FROM profiles p WHERE p.id IN (
        SELECT followed_comments.user_id FROM followed_comments
        UNION
        SELECT fp.user_id FROM followed_posts fp
        UNION
        SELECT followed_events.user_id FROM followed_events
    )
  )

  SELECT
    ARRAY(
        SELECT to_jsonb(d) FROM followed_posts d 
        UNION 
        SELECT to_jsonb(r) FROM realated_post r
    ) AS posts,
    ARRAY(SELECT to_jsonb(e) FROM followed_events e) AS events,
    ARRAY(SELECT to_jsonb(c) FROM followed_comments c) AS comments,
    ARRAY(SELECT to_jsonb(rp) FROM related_profiles rp) AS profiles;
END;
$$;


ALTER FUNCTION "public"."get_user_feed"("user_id" integer, "seen_post_ids" integer[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_meta_user_id"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    user_id TEXT;
BEGIN
    SELECT (current_setting('request.jwt.claims', true)::jsonb -> 'user_id')::TEXT
    INTO user_id;
    RETURN user_id;
END;
$$;


ALTER FUNCTION "public"."get_user_meta_user_id"() OWNER TO "postgres";


CREATE PROCEDURE "public"."mark_posts_seen"(IN "seen_user_id" integer, IN "post_ids" integer[])
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    INSERT INTO user_views (user_id, post_id)
    SELECT mark_posts_seen.seen_user_id, p.post_id
    FROM unnest(mark_posts_seen.post_ids) p(post_id)
    ON CONFLICT (user_id, post_id) DO NOTHING;
END;
$$;


ALTER PROCEDURE "public"."mark_posts_seen"(IN "seen_user_id" integer, IN "post_ids" integer[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."populate_feed"("user_id" integer DEFAULT NULL::integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Insert posts from followees into feeds table, avoiding duplicates
    INSERT INTO feeds (user_id, post_id, post_type, created_at)
    SELECT 
        f.follower_id,
        p.id AS post_id,
        p.type AS post_type,
        NOW() AS created_at
    FROM follows f
    JOIN posts p ON f.followee_id = p.user_id
    WHERE f.follower_id = populate_feed.user_id
    AND p.type != 'diary'
    AND p.image_urls IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 
        FROM feeds fe 
        WHERE fe.user_id = f.follower_id 
        AND fe.post_id = p.id
    );

END;
$$;


ALTER FUNCTION "public"."populate_feed"("user_id" integer) OWNER TO "postgres";


CREATE PROCEDURE "public"."populate_recommended_feed"()
    LANGUAGE "plpgsql"
    AS $$ BEGIN
    INSERT INTO recommended_feed (post_id, score, post_type, created_at)
    SELECT p.id,
        (COUNT(l.*) * 0.4) + (COUNT(c.*) * 0.3) + (
            (EXTRACT(EPOCH FROM NOW() - p.created_at)/3600 * 0.1) 
        ) + (
            COALESCE(jsonb_array_length(p.image_urls), 0) * 0.2
        ) AS score,
        p.type,
        NOW()::TIMESTAMP
    FROM posts p
        LEFT JOIN events l ON p.id = l.object_id
        AND (l.event_type = 'like')
        LEFT JOIN comments c ON p.id = c.post_id
    WHERE p.type != 'diary' 
      AND p.image_urls IS NOT NULL 
      AND jsonb_array_length(p.image_urls) > 0
    GROUP BY p.id,
        p.type
    ORDER BY score DESC
    LIMIT 500 ON CONFLICT (post_id) DO
    UPDATE
    SET score = EXCLUDED.score;
END;
$$;


ALTER PROCEDURE "public"."populate_recommended_feed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."populate_user_feed"("user_id" integer DEFAULT NULL::integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Insert posts from followees into feeds table, avoiding duplicates
    INSERT INTO user_feed (user_id, post_id, post_type, created_at)
    SELECT 
        f.follower_id,
        p.id,
        p.type,
        NOW() AS created_at
    FROM follows f
    JOIN posts p ON f.followee_id = p.user_id
    WHERE f.follower_id = populate_user_feed.user_id
    AND p.type != 'diary'
    AND p.image_urls IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 
        FROM user_feed fe 
        WHERE fe.user_id = f.follower_id 
        AND fe.post_id = p.id
    );
END;
$$;


ALTER FUNCTION "public"."populate_user_feed"("user_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recommend_feed"("user_id" integer, "seen_post_ids" integer[] DEFAULT NULL::integer[], "page_number" integer DEFAULT 1, "page_size" integer DEFAULT 10) RETURNS TABLE("posts" "jsonb"[], "events" "jsonb"[], "comments" "jsonb"[], "profiles" "jsonb"[])
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    feed_result RECORD;
    offset_value INT := (page_number - 1) * page_size;
BEGIN
    -- Mark provided posts as seen
    IF seen_post_ids IS NOT NULL THEN
        PERFORM set_posts_seen(seen_post_ids);
    END IF;

    -- Refresh recommendations
    INSERT INTO feeds (user_id, post_id, post_type, created_at)
    SELECT 
        recommend_feed.user_id,
        p.id AS post_id,
        p.type AS post_type,
        NOW() AS created_at
    FROM (
        SELECT 
            p.id,
            p.type
        FROM posts p
        JOIN post_scores ps ON p.id = ps.id
        WHERE p.user_id != recommend_feed.user_id
        AND NOT EXISTS (
            SELECT 1 
            FROM feeds fe 
            WHERE fe.user_id = recommend_feed.user_id
            AND fe.post_id = p.id
        )

        ORDER BY ps.score DESC
        LIMIT page_size
        OFFSET offset_value
    ) p;

    -- Get the feed data
    SELECT * INTO feed_result FROM get_user_feed(user_id);

    -- Return results with total count
    RETURN QUERY
    SELECT 
        feed_result.posts,
        feed_result.events,
        feed_result.comments,
        feed_result.profiles;
END;
$$;


ALTER FUNCTION "public"."recommend_feed"("user_id" integer, "seen_post_ids" integer[], "page_number" integer, "page_size" integer) OWNER TO "postgres";


CREATE PROCEDURE "public"."reset_user_views"(IN "user_id" integer DEFAULT NULL::integer)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Only delete when a valid user_id is provided (allow 0)
    IF reset_user_views.user_id IS NULL THEN
        RETURN;
    END IF;
    DELETE FROM user_views uv WHERE uv.user_id = reset_user_views.user_id;
END;
$$;


ALTER PROCEDURE "public"."reset_user_views"(IN "user_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_posts_seen"("post_ids" integer[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE feeds
    SET seen = TRUE
    WHERE feeds.post_id = ANY(post_ids);
END;
$$;


ALTER FUNCTION "public"."set_posts_seen"("post_ids" integer[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "storage"."can_insert_object"("bucketid" "text", "name" "text", "owner" "uuid", "metadata" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  INSERT INTO "storage"."objects" ("bucket_id", "name", "owner", "metadata") VALUES (bucketid, name, owner, metadata);
  -- hack to rollback the successful insert
  RAISE sqlstate 'PT200' using
  message = 'ROLLBACK',
  detail = 'rollback successful insert';
END
$$;


ALTER FUNCTION "storage"."can_insert_object"("bucketid" "text", "name" "text", "owner" "uuid", "metadata" "jsonb") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."extension"("name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
_parts text[];
_filename text;
BEGIN
	select string_to_array(name, '/') into _parts;
	select _parts[array_length(_parts,1)] into _filename;
	-- @todo return the last part instead of 2
	return reverse(split_part(reverse(_filename), '.', 1));
END
$$;


ALTER FUNCTION "storage"."extension"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."filename"("name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[array_length(_parts,1)];
END
$$;


ALTER FUNCTION "storage"."filename"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."foldername"("name" "text") RETURNS "text"[]
    LANGUAGE "plpgsql"
    AS $$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[1:array_length(_parts,1)-1];
END
$$;


ALTER FUNCTION "storage"."foldername"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."get_size_by_bucket"() RETURNS TABLE("size" bigint, "bucket_id" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    return query
        select sum((metadata->>'size')::int) as size, obj.bucket_id
        from "storage".objects as obj
        group by obj.bucket_id;
END
$$;


ALTER FUNCTION "storage"."get_size_by_bucket"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."list_multipart_uploads_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer DEFAULT 100, "next_key_token" "text" DEFAULT ''::"text", "next_upload_token" "text" DEFAULT ''::"text") RETURNS TABLE("key" "text", "id" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT DISTINCT ON(key COLLATE "C") * from (
            SELECT
                CASE
                    WHEN position($2 IN substring(key from length($1) + 1)) > 0 THEN
                        substring(key from 1 for length($1) + position($2 IN substring(key from length($1) + 1)))
                    ELSE
                        key
                END AS key, id, created_at
            FROM
                storage.s3_multipart_uploads
            WHERE
                bucket_id = $5 AND
                key ILIKE $1 || ''%'' AND
                CASE
                    WHEN $4 != '''' AND $6 = '''' THEN
                        CASE
                            WHEN position($2 IN substring(key from length($1) + 1)) > 0 THEN
                                substring(key from 1 for length($1) + position($2 IN substring(key from length($1) + 1))) COLLATE "C" > $4
                            ELSE
                                key COLLATE "C" > $4
                            END
                    ELSE
                        true
                END AND
                CASE
                    WHEN $6 != '''' THEN
                        id COLLATE "C" > $6
                    ELSE
                        true
                    END
            ORDER BY
                key COLLATE "C" ASC, created_at ASC) as e order by key COLLATE "C" LIMIT $3'
        USING prefix_param, delimiter_param, max_keys, next_key_token, bucket_id, next_upload_token;
END;
$_$;


ALTER FUNCTION "storage"."list_multipart_uploads_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer, "next_key_token" "text", "next_upload_token" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."list_objects_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer DEFAULT 100, "start_after" "text" DEFAULT ''::"text", "next_token" "text" DEFAULT ''::"text") RETURNS TABLE("name" "text", "id" "uuid", "metadata" "jsonb", "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT DISTINCT ON(name COLLATE "C") * from (
            SELECT
                CASE
                    WHEN position($2 IN substring(name from length($1) + 1)) > 0 THEN
                        substring(name from 1 for length($1) + position($2 IN substring(name from length($1) + 1)))
                    ELSE
                        name
                END AS name, id, metadata, updated_at
            FROM
                storage.objects
            WHERE
                bucket_id = $5 AND
                name ILIKE $1 || ''%'' AND
                CASE
                    WHEN $6 != '''' THEN
                    name COLLATE "C" > $6
                ELSE true END
                AND CASE
                    WHEN $4 != '''' THEN
                        CASE
                            WHEN position($2 IN substring(name from length($1) + 1)) > 0 THEN
                                substring(name from 1 for length($1) + position($2 IN substring(name from length($1) + 1))) COLLATE "C" > $4
                            ELSE
                                name COLLATE "C" > $4
                            END
                    ELSE
                        true
                END
            ORDER BY
                name COLLATE "C" ASC) as e order by name COLLATE "C" LIMIT $3'
        USING prefix_param, delimiter_param, max_keys, next_token, bucket_id, start_after;
END;
$_$;


ALTER FUNCTION "storage"."list_objects_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer, "start_after" "text", "next_token" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."operation"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $$
BEGIN
    RETURN current_setting('storage.operation', true);
END;
$$;


ALTER FUNCTION "storage"."operation"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."search"("prefix" "text", "bucketname" "text", "limits" integer DEFAULT 100, "levels" integer DEFAULT 1, "offsets" integer DEFAULT 0, "search" "text" DEFAULT ''::"text", "sortcolumn" "text" DEFAULT 'name'::"text", "sortorder" "text" DEFAULT 'asc'::"text") RETURNS TABLE("name" "text", "id" "uuid", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" STABLE
    AS $_$
declare
  v_order_by text;
  v_sort_order text;
begin
  case
    when sortcolumn = 'name' then
      v_order_by = 'name';
    when sortcolumn = 'updated_at' then
      v_order_by = 'updated_at';
    when sortcolumn = 'created_at' then
      v_order_by = 'created_at';
    when sortcolumn = 'last_accessed_at' then
      v_order_by = 'last_accessed_at';
    else
      v_order_by = 'name';
  end case;

  case
    when sortorder = 'asc' then
      v_sort_order = 'asc';
    when sortorder = 'desc' then
      v_sort_order = 'desc';
    else
      v_sort_order = 'asc';
  end case;

  v_order_by = v_order_by || ' ' || v_sort_order;

  return query execute
    'with folders as (
       select path_tokens[$1] as folder
       from storage.objects
         where objects.name ilike $2 || $3 || ''%''
           and bucket_id = $4
           and array_length(objects.path_tokens, 1) <> $1
       group by folder
       order by folder ' || v_sort_order || '
     )
     (select folder as "name",
            null as id,
            null as updated_at,
            null as created_at,
            null as last_accessed_at,
            null as metadata from folders)
     union all
     (select path_tokens[$1] as "name",
            id,
            updated_at,
            created_at,
            last_accessed_at,
            metadata
     from storage.objects
     where objects.name ilike $2 || $3 || ''%''
       and bucket_id = $4
       and array_length(objects.path_tokens, 1) = $1
     order by ' || v_order_by || ')
     limit $5
     offset $6' using levels, prefix, search, bucketname, limits, offsets;
end;
$_$;


ALTER FUNCTION "storage"."search"("prefix" "text", "bucketname" "text", "limits" integer, "levels" integer, "offsets" integer, "search" "text", "sortcolumn" "text", "sortorder" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW; 
END;
$$;


ALTER FUNCTION "storage"."update_updated_at_column"() OWNER TO "supabase_storage_admin";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "auth"."audit_log_entries" (
    "instance_id" "uuid",
    "id" "uuid" NOT NULL,
    "payload" "json",
    "created_at" timestamp with time zone,
    "ip_address" character varying(64) DEFAULT ''::character varying NOT NULL
);


ALTER TABLE "auth"."audit_log_entries" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."audit_log_entries" IS 'Auth: Audit trail for user actions.';



CREATE TABLE IF NOT EXISTS "auth"."flow_state" (
    "id" "uuid" NOT NULL,
    "user_id" "uuid",
    "auth_code" "text" NOT NULL,
    "code_challenge_method" "auth"."code_challenge_method" NOT NULL,
    "code_challenge" "text" NOT NULL,
    "provider_type" "text" NOT NULL,
    "provider_access_token" "text",
    "provider_refresh_token" "text",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "authentication_method" "text" NOT NULL,
    "auth_code_issued_at" timestamp with time zone
);


ALTER TABLE "auth"."flow_state" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."flow_state" IS 'stores metadata for pkce logins';



CREATE TABLE IF NOT EXISTS "auth"."identities" (
    "provider_id" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "identity_data" "jsonb" NOT NULL,
    "provider" "text" NOT NULL,
    "last_sign_in_at" timestamp with time zone,
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "email" "text" GENERATED ALWAYS AS ("lower"(("identity_data" ->> 'email'::"text"))) STORED,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "auth"."identities" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."identities" IS 'Auth: Stores identities associated to a user.';



COMMENT ON COLUMN "auth"."identities"."email" IS 'Auth: Email is a generated column that references the optional email property in the identity_data';



CREATE TABLE IF NOT EXISTS "auth"."instances" (
    "id" "uuid" NOT NULL,
    "uuid" "uuid",
    "raw_base_config" "text",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone
);


ALTER TABLE "auth"."instances" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."instances" IS 'Auth: Manages users across multiple sites.';



CREATE TABLE IF NOT EXISTS "auth"."mfa_amr_claims" (
    "session_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone NOT NULL,
    "authentication_method" "text" NOT NULL,
    "id" "uuid" NOT NULL
);


ALTER TABLE "auth"."mfa_amr_claims" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."mfa_amr_claims" IS 'auth: stores authenticator method reference claims for multi factor authentication';



CREATE TABLE IF NOT EXISTS "auth"."mfa_challenges" (
    "id" "uuid" NOT NULL,
    "factor_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone NOT NULL,
    "verified_at" timestamp with time zone,
    "ip_address" "inet" NOT NULL,
    "otp_code" "text",
    "web_authn_session_data" "jsonb"
);


ALTER TABLE "auth"."mfa_challenges" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."mfa_challenges" IS 'auth: stores metadata about challenge requests made';



CREATE TABLE IF NOT EXISTS "auth"."mfa_factors" (
    "id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "friendly_name" "text",
    "factor_type" "auth"."factor_type" NOT NULL,
    "status" "auth"."factor_status" NOT NULL,
    "created_at" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone NOT NULL,
    "secret" "text",
    "phone" "text",
    "last_challenged_at" timestamp with time zone,
    "web_authn_credential" "jsonb",
    "web_authn_aaguid" "uuid"
);


ALTER TABLE "auth"."mfa_factors" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."mfa_factors" IS 'auth: stores metadata about factors';



CREATE TABLE IF NOT EXISTS "auth"."one_time_tokens" (
    "id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token_type" "auth"."one_time_token_type" NOT NULL,
    "token_hash" "text" NOT NULL,
    "relates_to" "text" NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "one_time_tokens_token_hash_check" CHECK (("char_length"("token_hash") > 0))
);


ALTER TABLE "auth"."one_time_tokens" OWNER TO "supabase_auth_admin";


CREATE TABLE IF NOT EXISTS "auth"."refresh_tokens" (
    "instance_id" "uuid",
    "id" bigint NOT NULL,
    "token" character varying(255),
    "user_id" character varying(255),
    "revoked" boolean,
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "parent" character varying(255),
    "session_id" "uuid"
);


ALTER TABLE "auth"."refresh_tokens" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."refresh_tokens" IS 'Auth: Store of tokens used to refresh JWT tokens once they expire.';



CREATE SEQUENCE IF NOT EXISTS "auth"."refresh_tokens_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "auth"."refresh_tokens_id_seq" OWNER TO "supabase_auth_admin";


ALTER SEQUENCE "auth"."refresh_tokens_id_seq" OWNED BY "auth"."refresh_tokens"."id";



CREATE TABLE IF NOT EXISTS "auth"."saml_providers" (
    "id" "uuid" NOT NULL,
    "sso_provider_id" "uuid" NOT NULL,
    "entity_id" "text" NOT NULL,
    "metadata_xml" "text" NOT NULL,
    "metadata_url" "text",
    "attribute_mapping" "jsonb",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "name_id_format" "text",
    CONSTRAINT "entity_id not empty" CHECK (("char_length"("entity_id") > 0)),
    CONSTRAINT "metadata_url not empty" CHECK ((("metadata_url" = NULL::"text") OR ("char_length"("metadata_url") > 0))),
    CONSTRAINT "metadata_xml not empty" CHECK (("char_length"("metadata_xml") > 0))
);


ALTER TABLE "auth"."saml_providers" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."saml_providers" IS 'Auth: Manages SAML Identity Provider connections.';



CREATE TABLE IF NOT EXISTS "auth"."saml_relay_states" (
    "id" "uuid" NOT NULL,
    "sso_provider_id" "uuid" NOT NULL,
    "request_id" "text" NOT NULL,
    "for_email" "text",
    "redirect_to" "text",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "flow_state_id" "uuid",
    CONSTRAINT "request_id not empty" CHECK (("char_length"("request_id") > 0))
);


ALTER TABLE "auth"."saml_relay_states" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."saml_relay_states" IS 'Auth: Contains SAML Relay State information for each Service Provider initiated login.';



CREATE TABLE IF NOT EXISTS "auth"."schema_migrations" (
    "version" character varying(255) NOT NULL
);


ALTER TABLE "auth"."schema_migrations" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."schema_migrations" IS 'Auth: Manages updates to the auth system.';



CREATE TABLE IF NOT EXISTS "auth"."sessions" (
    "id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "factor_id" "uuid",
    "aal" "auth"."aal_level",
    "not_after" timestamp with time zone,
    "refreshed_at" timestamp without time zone,
    "user_agent" "text",
    "ip" "inet",
    "tag" "text"
);


ALTER TABLE "auth"."sessions" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."sessions" IS 'Auth: Stores session data associated to a user.';



COMMENT ON COLUMN "auth"."sessions"."not_after" IS 'Auth: Not after is a nullable column that contains a timestamp after which the session should be regarded as expired.';



CREATE TABLE IF NOT EXISTS "auth"."sso_domains" (
    "id" "uuid" NOT NULL,
    "sso_provider_id" "uuid" NOT NULL,
    "domain" "text" NOT NULL,
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    CONSTRAINT "domain not empty" CHECK (("char_length"("domain") > 0))
);


ALTER TABLE "auth"."sso_domains" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."sso_domains" IS 'Auth: Manages SSO email address domain mapping to an SSO Identity Provider.';



CREATE TABLE IF NOT EXISTS "auth"."sso_providers" (
    "id" "uuid" NOT NULL,
    "resource_id" "text",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    CONSTRAINT "resource_id not empty" CHECK ((("resource_id" = NULL::"text") OR ("char_length"("resource_id") > 0)))
);


ALTER TABLE "auth"."sso_providers" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."sso_providers" IS 'Auth: Manages SSO identity provider information; see saml_providers for SAML.';



COMMENT ON COLUMN "auth"."sso_providers"."resource_id" IS 'Auth: Uniquely identifies a SSO provider according to a user-chosen resource ID (case insensitive), useful in infrastructure as code.';



CREATE TABLE IF NOT EXISTS "auth"."users" (
    "instance_id" "uuid",
    "id" "uuid" NOT NULL,
    "aud" character varying(255),
    "role" character varying(255),
    "email" character varying(255),
    "encrypted_password" character varying(255),
    "email_confirmed_at" timestamp with time zone,
    "invited_at" timestamp with time zone,
    "confirmation_token" character varying(255),
    "confirmation_sent_at" timestamp with time zone,
    "recovery_token" character varying(255),
    "recovery_sent_at" timestamp with time zone,
    "email_change_token_new" character varying(255),
    "email_change" character varying(255),
    "email_change_sent_at" timestamp with time zone,
    "last_sign_in_at" timestamp with time zone,
    "raw_app_meta_data" "jsonb",
    "raw_user_meta_data" "jsonb",
    "is_super_admin" boolean,
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "phone" "text" DEFAULT NULL::character varying,
    "phone_confirmed_at" timestamp with time zone,
    "phone_change" "text" DEFAULT ''::character varying,
    "phone_change_token" character varying(255) DEFAULT ''::character varying,
    "phone_change_sent_at" timestamp with time zone,
    "confirmed_at" timestamp with time zone GENERATED ALWAYS AS (LEAST("email_confirmed_at", "phone_confirmed_at")) STORED,
    "email_change_token_current" character varying(255) DEFAULT ''::character varying,
    "email_change_confirm_status" smallint DEFAULT 0,
    "banned_until" timestamp with time zone,
    "reauthentication_token" character varying(255) DEFAULT ''::character varying,
    "reauthentication_sent_at" timestamp with time zone,
    "is_sso_user" boolean DEFAULT false NOT NULL,
    "deleted_at" timestamp with time zone,
    "is_anonymous" boolean DEFAULT false NOT NULL,
    CONSTRAINT "users_email_change_confirm_status_check" CHECK ((("email_change_confirm_status" >= 0) AND ("email_change_confirm_status" <= 2)))
);


ALTER TABLE "auth"."users" OWNER TO "supabase_auth_admin";


COMMENT ON TABLE "auth"."users" IS 'Auth: Stores user login data within a secure schema.';



COMMENT ON COLUMN "auth"."users"."is_sso_user" IS 'Auth: Set this column to true when the account comes from SSO. These accounts can have duplicate emails.';



CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" bigint NOT NULL,
    "post_id" bigint,
    "username" "text",
    "author_email" "text",
    "author_ip" "text",
    "created_at" timestamp with time zone,
    "modified_at" timestamp with time zone,
    "content" "text",
    "karma" "text",
    "approved" "text",
    "agent" "text",
    "type" "text",
    "parent_id" bigint,
    "user_id" bigint NOT NULL,
    "week_number" "text"
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


COMMENT ON TABLE "public"."comments" IS '@graphql({"name": "Comment"})';



ALTER TABLE "public"."comments" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."comments_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."diaries" (
    "id" bigint NOT NULL,
    "user_id" bigint,
    "name" "text",
    "title" "text",
    "status" "text",
    "created_at" timestamp with time zone,
    "modified_at" timestamp with time zone,
    "seed_bank" "text",
    "strain" "text",
    "light_cycle" "text",
    "room_type" "text",
    "grow_area" "text",
    "grow_medium" "text",
    "grow_techniques" "text",
    "vega_light_type" "text",
    "vega_light_watts" "json",
    "flora_light_type" "text",
    "flora_light_watts" "json",
    "current_week" "text",
    "thumbnail_url" "text",
    "last_edited_week" integer
);


ALTER TABLE "public"."diaries" OWNER TO "postgres";


COMMENT ON TABLE "public"."diaries" IS '@graphql({"name": "Diary"})';



CREATE TABLE IF NOT EXISTS "public"."diaries_follows" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "diary_id" bigint,
    "user_id" bigint
);


ALTER TABLE "public"."diaries_follows" OWNER TO "postgres";


ALTER TABLE "public"."diaries" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."diaries_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."diaries_follows" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."diaries_subscribers_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" bigint NOT NULL,
    "user_id" bigint DEFAULT '0'::bigint,
    "title" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "modified_at" timestamp with time zone DEFAULT "now"(),
    "excerpt" "text",
    "event_type" "text",
    "audience" "text",
    "object_id" bigint DEFAULT '0'::bigint,
    "object_parent_id" bigint DEFAULT 0,
    "comment_id" bigint DEFAULT '0'::bigint,
    "description" "text",
    "object_type" "text"
);


ALTER TABLE "public"."events" OWNER TO "postgres";


COMMENT ON TABLE "public"."events" IS '@graphql({"name": "Event"})';



ALTER TABLE "public"."events" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."favorites" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "post_id" bigint,
    "user_id" bigint,
    "group" "text"
);


ALTER TABLE "public"."favorites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."follows" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "follower_id" bigint NOT NULL,
    "followee_id" bigint NOT NULL
);


ALTER TABLE "public"."follows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" bigint NOT NULL,
    "user_id" bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "read_at" timestamp without time zone,
    "status" integer DEFAULT 0,
    "event_id" bigint
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


ALTER TABLE "public"."notifications" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."notifications_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."posts" (
    "id" bigint NOT NULL,
    "user_id" bigint DEFAULT '0'::bigint,
    "name" "text" DEFAULT ''::"text" NOT NULL,
    "title" "text" DEFAULT ''::"text",
    "status" "text" DEFAULT ''::"text",
    "content" "text" DEFAULT ''::"text",
    "parent_id" bigint DEFAULT '0'::bigint,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "modified_at" timestamp without time zone DEFAULT "now"(),
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "type" "text" DEFAULT ''::"text",
    "thumbnail_url" "text",
    "image_urls" "jsonb"
);


ALTER TABLE "public"."posts" OWNER TO "postgres";


COMMENT ON TABLE "public"."posts" IS 'diaries with weeks and questions';



ALTER TABLE "public"."favorites" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."posts_follows_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."posts" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."posts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" bigint NOT NULL,
    "created_at" time without time zone DEFAULT "now"() NOT NULL,
    "uid" "uuid" DEFAULT "auth"."uid"(),
    "name" character varying DEFAULT ''::character varying,
    "username" character varying DEFAULT ''::character varying NOT NULL,
    "email" character varying DEFAULT ''::character varying,
    "avatar_url" character varying,
    "avatar_xy" "jsonb",
    "last_login" timestamp with time zone,
    "liked_mail" boolean,
    "bookmarked_mail" boolean,
    "following_mail" boolean,
    "comment_mail" boolean,
    "points" bigint,
    "following" "json",
    "bookmarked" "json",
    "activities" "json",
    "notifications" "json",
    "desc" "text",
    "capabilities" "json",
    "active" boolean,
    "updated_at" timestamp with time zone,
    "is_admin" boolean,
    "background_url" character varying,
    "postCount" bigint,
    "dark_mode" boolean
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON TABLE "public"."profiles" IS '@graphql({"name": "Profile"})';



CREATE TABLE IF NOT EXISTS "public"."questions" (
    "id" bigint NOT NULL,
    "user_id" bigint,
    "name" "text",
    "title" "text",
    "content" "text",
    "status" "text",
    "created_at" timestamp with time zone,
    "modified_at" timestamp with time zone,
    "excerpt" "text",
    "comment_count" bigint,
    "diary_id" bigint,
    "week_number" integer,
    "best_answer_id" bigint,
    "thumbnail_url" "text",
    "tags" "jsonb",
    "image_urls" "jsonb",
    "captions" "jsonb"
);


ALTER TABLE "public"."questions" OWNER TO "postgres";


ALTER TABLE "public"."questions" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."questions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."recommended_feed" (
    "post_id" bigint NOT NULL,
    "score" double precision NOT NULL,
    "post_type" character varying(10) NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."recommended_feed" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."topics" (
    "id" bigint NOT NULL,
    "user_id" bigint,
    "title" "text",
    "content" "text",
    "created_at" timestamp with time zone,
    "modified_at" timestamp with time zone,
    "excerpt" "text",
    "comment_count" "text",
    "topic_type" "text",
    "object_id" bigint DEFAULT '0'::bigint,
    "parent_id" bigint DEFAULT '0'::bigint,
    "subscribers" "text",
    "events" "text"
);


ALTER TABLE "public"."topics" OWNER TO "postgres";


COMMENT ON TABLE "public"."topics" IS '@graphql({"name": "Topic"})';



CREATE TABLE IF NOT EXISTS "public"."user_feed" (
    "user_id" bigint NOT NULL,
    "post_id" bigint NOT NULL,
    "post_type" character varying(10) NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_feed" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_views" (
    "user_id" bigint NOT NULL,
    "post_id" bigint NOT NULL,
    "viewed_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_views" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_views_archive" (
    "user_id" bigint NOT NULL,
    "post_id" bigint NOT NULL,
    "viewed_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_views_archive" OWNER TO "postgres";


ALTER TABLE "public"."profiles" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."users_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."weeks" (
    "id" bigint NOT NULL,
    "user_id" bigint,
    "diary_id" bigint,
    "title" "text",
    "created_at" timestamp with time zone,
    "modified_at" timestamp with time zone,
    "content" "text",
    "status" "text",
    "stage" "text",
    "week_number" "text",
    "height" "text",
    "light_schedule" "text",
    "day_air_temperature" "text",
    "night_air_temperature" "text",
    "nutrients" "text",
    "ph" "text",
    "air_humidity" "text",
    "smell" "text",
    "lamp_to_plant_distance" "text",
    "watering_volume" "text",
    "watering_freq" "text",
    "pot_size" "text",
    "dry_weight" "text",
    "wet_weight" "text",
    "total_plants" "text",
    "total_power" "text",
    "total_energy" "text",
    "taste" "text",
    "feel" "text",
    "grow_difficulty" "text",
    "plant_resistance" "text",
    "image_urls" "jsonb",
    "grow_techniques" "jsonb",
    "captions" "jsonb"
);


ALTER TABLE "public"."weeks" OWNER TO "postgres";


COMMENT ON TABLE "public"."weeks" IS '@graphql({"name": "Week"})';



ALTER TABLE "public"."weeks" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."weeks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "storage"."buckets" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "owner" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "public" boolean DEFAULT false,
    "avif_autodetection" boolean DEFAULT false,
    "file_size_limit" bigint,
    "allowed_mime_types" "text"[],
    "owner_id" "text"
);


ALTER TABLE "storage"."buckets" OWNER TO "supabase_storage_admin";


COMMENT ON COLUMN "storage"."buckets"."owner" IS 'Field is deprecated, use owner_id instead';



CREATE TABLE IF NOT EXISTS "storage"."migrations" (
    "id" integer NOT NULL,
    "name" character varying(100) NOT NULL,
    "hash" character varying(40) NOT NULL,
    "executed_at" timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "storage"."migrations" OWNER TO "supabase_storage_admin";


CREATE TABLE IF NOT EXISTS "storage"."objects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bucket_id" "text",
    "name" "text",
    "owner" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "last_accessed_at" timestamp with time zone DEFAULT "now"(),
    "metadata" "jsonb",
    "path_tokens" "text"[] GENERATED ALWAYS AS ("string_to_array"("name", '/'::"text")) STORED,
    "version" "text",
    "owner_id" "text",
    "user_metadata" "jsonb"
);


ALTER TABLE "storage"."objects" OWNER TO "supabase_storage_admin";


COMMENT ON COLUMN "storage"."objects"."owner" IS 'Field is deprecated, use owner_id instead';



CREATE TABLE IF NOT EXISTS "storage"."s3_multipart_uploads" (
    "id" "text" NOT NULL,
    "in_progress_size" bigint DEFAULT 0 NOT NULL,
    "upload_signature" "text" NOT NULL,
    "bucket_id" "text" NOT NULL,
    "key" "text" NOT NULL COLLATE "pg_catalog"."C",
    "version" "text" NOT NULL,
    "owner_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_metadata" "jsonb"
);


ALTER TABLE "storage"."s3_multipart_uploads" OWNER TO "supabase_storage_admin";


CREATE TABLE IF NOT EXISTS "storage"."s3_multipart_uploads_parts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "upload_id" "text" NOT NULL,
    "size" bigint DEFAULT 0 NOT NULL,
    "part_number" integer NOT NULL,
    "bucket_id" "text" NOT NULL,
    "key" "text" NOT NULL COLLATE "pg_catalog"."C",
    "etag" "text" NOT NULL,
    "owner_id" "text",
    "version" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "storage"."s3_multipart_uploads_parts" OWNER TO "supabase_storage_admin";


ALTER TABLE ONLY "auth"."refresh_tokens" ALTER COLUMN "id" SET DEFAULT "nextval"('"auth"."refresh_tokens_id_seq"'::"regclass");



ALTER TABLE ONLY "auth"."mfa_amr_claims"
    ADD CONSTRAINT "amr_id_pk" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."audit_log_entries"
    ADD CONSTRAINT "audit_log_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."flow_state"
    ADD CONSTRAINT "flow_state_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."identities"
    ADD CONSTRAINT "identities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."identities"
    ADD CONSTRAINT "identities_provider_id_provider_unique" UNIQUE ("provider_id", "provider");



ALTER TABLE ONLY "auth"."instances"
    ADD CONSTRAINT "instances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."mfa_amr_claims"
    ADD CONSTRAINT "mfa_amr_claims_session_id_authentication_method_pkey" UNIQUE ("session_id", "authentication_method");



ALTER TABLE ONLY "auth"."mfa_challenges"
    ADD CONSTRAINT "mfa_challenges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."mfa_factors"
    ADD CONSTRAINT "mfa_factors_last_challenged_at_key" UNIQUE ("last_challenged_at");



ALTER TABLE ONLY "auth"."mfa_factors"
    ADD CONSTRAINT "mfa_factors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."one_time_tokens"
    ADD CONSTRAINT "one_time_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."refresh_tokens"
    ADD CONSTRAINT "refresh_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."refresh_tokens"
    ADD CONSTRAINT "refresh_tokens_token_unique" UNIQUE ("token");



ALTER TABLE ONLY "auth"."saml_providers"
    ADD CONSTRAINT "saml_providers_entity_id_key" UNIQUE ("entity_id");



ALTER TABLE ONLY "auth"."saml_providers"
    ADD CONSTRAINT "saml_providers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."saml_relay_states"
    ADD CONSTRAINT "saml_relay_states_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."schema_migrations"
    ADD CONSTRAINT "schema_migrations_pkey" PRIMARY KEY ("version");



ALTER TABLE ONLY "auth"."sessions"
    ADD CONSTRAINT "sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."sso_domains"
    ADD CONSTRAINT "sso_domains_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."sso_providers"
    ADD CONSTRAINT "sso_providers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "auth"."users"
    ADD CONSTRAINT "users_phone_key" UNIQUE ("phone");



ALTER TABLE ONLY "auth"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."diaries_follows"
    ADD CONSTRAINT "diaries_follows_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."diaries"
    ADD CONSTRAINT "diaries_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."diaries"
    ADD CONSTRAINT "diaries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."diaries_follows"
    ADD CONSTRAINT "diaries_subscribers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "followers_pkey" PRIMARY KEY ("follower_id", "followee_id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "posts_follows_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "posts_follows_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."questions"
    ADD CONSTRAINT "questions_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."questions"
    ADD CONSTRAINT "questions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recommended_feed"
    ADD CONSTRAINT "recommended_feed_pkey" PRIMARY KEY ("post_id");



ALTER TABLE ONLY "public"."topics"
    ADD CONSTRAINT "topics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_feed"
    ADD CONSTRAINT "user_feed_pkey" PRIMARY KEY ("user_id", "post_id");



ALTER TABLE ONLY "public"."user_views_archive"
    ADD CONSTRAINT "user_views_archive_pkey" PRIMARY KEY ("user_id", "post_id");



ALTER TABLE ONLY "public"."user_views"
    ADD CONSTRAINT "user_views_pkey" PRIMARY KEY ("user_id", "post_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "users_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."weeks"
    ADD CONSTRAINT "weeks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."buckets"
    ADD CONSTRAINT "buckets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."migrations"
    ADD CONSTRAINT "migrations_name_key" UNIQUE ("name");



ALTER TABLE ONLY "storage"."migrations"
    ADD CONSTRAINT "migrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."objects"
    ADD CONSTRAINT "objects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads"
    ADD CONSTRAINT "s3_multipart_uploads_pkey" PRIMARY KEY ("id");



CREATE INDEX "audit_logs_instance_id_idx" ON "auth"."audit_log_entries" USING "btree" ("instance_id");



CREATE UNIQUE INDEX "confirmation_token_idx" ON "auth"."users" USING "btree" ("confirmation_token") WHERE (("confirmation_token")::"text" !~ '^[0-9 ]*$'::"text");



CREATE UNIQUE INDEX "email_change_token_current_idx" ON "auth"."users" USING "btree" ("email_change_token_current") WHERE (("email_change_token_current")::"text" !~ '^[0-9 ]*$'::"text");



CREATE UNIQUE INDEX "email_change_token_new_idx" ON "auth"."users" USING "btree" ("email_change_token_new") WHERE (("email_change_token_new")::"text" !~ '^[0-9 ]*$'::"text");



CREATE INDEX "factor_id_created_at_idx" ON "auth"."mfa_factors" USING "btree" ("user_id", "created_at");



CREATE INDEX "flow_state_created_at_idx" ON "auth"."flow_state" USING "btree" ("created_at" DESC);



CREATE INDEX "identities_email_idx" ON "auth"."identities" USING "btree" ("email" "text_pattern_ops");



COMMENT ON INDEX "auth"."identities_email_idx" IS 'Auth: Ensures indexed queries on the email column';



CREATE INDEX "identities_user_id_idx" ON "auth"."identities" USING "btree" ("user_id");



CREATE INDEX "idx_auth_code" ON "auth"."flow_state" USING "btree" ("auth_code");



CREATE INDEX "idx_user_id_auth_method" ON "auth"."flow_state" USING "btree" ("user_id", "authentication_method");



CREATE INDEX "mfa_challenge_created_at_idx" ON "auth"."mfa_challenges" USING "btree" ("created_at" DESC);



CREATE UNIQUE INDEX "mfa_factors_user_friendly_name_unique" ON "auth"."mfa_factors" USING "btree" ("friendly_name", "user_id") WHERE (TRIM(BOTH FROM "friendly_name") <> ''::"text");



CREATE INDEX "mfa_factors_user_id_idx" ON "auth"."mfa_factors" USING "btree" ("user_id");



CREATE INDEX "one_time_tokens_relates_to_hash_idx" ON "auth"."one_time_tokens" USING "hash" ("relates_to");



CREATE INDEX "one_time_tokens_token_hash_hash_idx" ON "auth"."one_time_tokens" USING "hash" ("token_hash");



CREATE UNIQUE INDEX "one_time_tokens_user_id_token_type_key" ON "auth"."one_time_tokens" USING "btree" ("user_id", "token_type");



CREATE UNIQUE INDEX "reauthentication_token_idx" ON "auth"."users" USING "btree" ("reauthentication_token") WHERE (("reauthentication_token")::"text" !~ '^[0-9 ]*$'::"text");



CREATE UNIQUE INDEX "recovery_token_idx" ON "auth"."users" USING "btree" ("recovery_token") WHERE (("recovery_token")::"text" !~ '^[0-9 ]*$'::"text");



CREATE INDEX "refresh_tokens_instance_id_idx" ON "auth"."refresh_tokens" USING "btree" ("instance_id");



CREATE INDEX "refresh_tokens_instance_id_user_id_idx" ON "auth"."refresh_tokens" USING "btree" ("instance_id", "user_id");



CREATE INDEX "refresh_tokens_parent_idx" ON "auth"."refresh_tokens" USING "btree" ("parent");



CREATE INDEX "refresh_tokens_session_id_revoked_idx" ON "auth"."refresh_tokens" USING "btree" ("session_id", "revoked");



CREATE INDEX "refresh_tokens_updated_at_idx" ON "auth"."refresh_tokens" USING "btree" ("updated_at" DESC);



CREATE INDEX "saml_providers_sso_provider_id_idx" ON "auth"."saml_providers" USING "btree" ("sso_provider_id");



CREATE INDEX "saml_relay_states_created_at_idx" ON "auth"."saml_relay_states" USING "btree" ("created_at" DESC);



CREATE INDEX "saml_relay_states_for_email_idx" ON "auth"."saml_relay_states" USING "btree" ("for_email");



CREATE INDEX "saml_relay_states_sso_provider_id_idx" ON "auth"."saml_relay_states" USING "btree" ("sso_provider_id");



CREATE INDEX "sessions_not_after_idx" ON "auth"."sessions" USING "btree" ("not_after" DESC);



CREATE INDEX "sessions_user_id_idx" ON "auth"."sessions" USING "btree" ("user_id");



CREATE UNIQUE INDEX "sso_domains_domain_idx" ON "auth"."sso_domains" USING "btree" ("lower"("domain"));



CREATE INDEX "sso_domains_sso_provider_id_idx" ON "auth"."sso_domains" USING "btree" ("sso_provider_id");



CREATE UNIQUE INDEX "sso_providers_resource_id_idx" ON "auth"."sso_providers" USING "btree" ("lower"("resource_id"));



CREATE UNIQUE INDEX "unique_phone_factor_per_user" ON "auth"."mfa_factors" USING "btree" ("user_id", "phone");



CREATE INDEX "user_id_created_at_idx" ON "auth"."sessions" USING "btree" ("user_id", "created_at");



CREATE UNIQUE INDEX "users_email_partial_key" ON "auth"."users" USING "btree" ("email") WHERE ("is_sso_user" = false);



COMMENT ON INDEX "auth"."users_email_partial_key" IS 'Auth: A partial unique index that applies only when is_sso_user is false';



CREATE INDEX "users_instance_id_email_idx" ON "auth"."users" USING "btree" ("instance_id", "lower"(("email")::"text"));



CREATE INDEX "users_instance_id_idx" ON "auth"."users" USING "btree" ("instance_id");



CREATE INDEX "users_is_anonymous_idx" ON "auth"."users" USING "btree" ("is_anonymous");



CREATE INDEX "idx_comments_post_id" ON "public"."comments" USING "btree" ("post_id");



CREATE INDEX "idx_diaries_name" ON "public"."diaries" USING "btree" ("name");



CREATE INDEX "idx_diaries_user_id" ON "public"."diaries" USING "btree" ("user_id");



CREATE INDEX "idx_events_comment_id" ON "public"."events" USING "btree" ("comment_id");



CREATE INDEX "idx_events_object_id" ON "public"."events" USING "btree" ("object_id");



CREATE INDEX "idx_posts_type" ON "public"."posts" USING "btree" ("type");



CREATE INDEX "idx_profiles_username" ON "public"."profiles" USING "btree" ("username");



CREATE INDEX "idx_questions_name" ON "public"."questions" USING "btree" ("name");



CREATE INDEX "idx_questions_user_id" ON "public"."questions" USING "btree" ("user_id");



CREATE INDEX "idx_recommended_feed_post" ON "public"."recommended_feed" USING "btree" ("post_id");



CREATE INDEX "idx_recommended_feed_post_type" ON "public"."recommended_feed" USING "btree" ("post_type");



CREATE INDEX "idx_user_feed_post" ON "public"."user_feed" USING "btree" ("post_id");



CREATE INDEX "idx_user_feed_post_type" ON "public"."user_feed" USING "btree" ("post_type");



CREATE INDEX "idx_user_feed_user" ON "public"."user_feed" USING "btree" ("user_id");



CREATE INDEX "idx_user_views_post" ON "public"."user_views" USING "btree" ("post_id");



CREATE INDEX "idx_user_views_user" ON "public"."user_views" USING "btree" ("user_id");



CREATE INDEX "idx_weeks_diary_id" ON "public"."weeks" USING "btree" ("diary_id");



CREATE UNIQUE INDEX "bname" ON "storage"."buckets" USING "btree" ("name");



CREATE UNIQUE INDEX "bucketid_objname" ON "storage"."objects" USING "btree" ("bucket_id", "name");



CREATE INDEX "idx_multipart_uploads_list" ON "storage"."s3_multipart_uploads" USING "btree" ("bucket_id", "key", "created_at");



CREATE INDEX "idx_objects_bucket_id_name" ON "storage"."objects" USING "btree" ("bucket_id", "name" COLLATE "C");



CREATE INDEX "name_prefix_search" ON "storage"."objects" USING "btree" ("name" "text_pattern_ops");



CREATE OR REPLACE TRIGGER "on_auth_user_created" AFTER INSERT ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "public"."create_user_profile"();



CREATE OR REPLACE TRIGGER "update_objects_updated_at" BEFORE UPDATE ON "storage"."objects" FOR EACH ROW EXECUTE FUNCTION "storage"."update_updated_at_column"();



ALTER TABLE ONLY "auth"."identities"
    ADD CONSTRAINT "identities_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."mfa_amr_claims"
    ADD CONSTRAINT "mfa_amr_claims_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "auth"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."mfa_challenges"
    ADD CONSTRAINT "mfa_challenges_auth_factor_id_fkey" FOREIGN KEY ("factor_id") REFERENCES "auth"."mfa_factors"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."mfa_factors"
    ADD CONSTRAINT "mfa_factors_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."one_time_tokens"
    ADD CONSTRAINT "one_time_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."refresh_tokens"
    ADD CONSTRAINT "refresh_tokens_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "auth"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."saml_providers"
    ADD CONSTRAINT "saml_providers_sso_provider_id_fkey" FOREIGN KEY ("sso_provider_id") REFERENCES "auth"."sso_providers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."saml_relay_states"
    ADD CONSTRAINT "saml_relay_states_flow_state_id_fkey" FOREIGN KEY ("flow_state_id") REFERENCES "auth"."flow_state"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."saml_relay_states"
    ADD CONSTRAINT "saml_relay_states_sso_provider_id_fkey" FOREIGN KEY ("sso_provider_id") REFERENCES "auth"."sso_providers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."sessions"
    ADD CONSTRAINT "sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "auth"."sso_domains"
    ADD CONSTRAINT "sso_domains_sso_provider_id_fkey" FOREIGN KEY ("sso_provider_id") REFERENCES "auth"."sso_providers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."diaries_follows"
    ADD CONSTRAINT "diaries_subscribers_diary_id_fkey" FOREIGN KEY ("diary_id") REFERENCES "public"."diaries"("id");



ALTER TABLE ONLY "public"."diaries_follows"
    ADD CONSTRAINT "diaries_subscribers_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."diaries"
    ADD CONSTRAINT "diaries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "followers_followee_id_fkey" FOREIGN KEY ("followee_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "followers_follower_id_fkey" FOREIGN KEY ("follower_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "posts_follows_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id");



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "posts_follows_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_uid_fkey" FOREIGN KEY ("uid") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."questions"
    ADD CONSTRAINT "questions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "storage"."objects"
    ADD CONSTRAINT "objects_bucketId_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads"
    ADD CONSTRAINT "s3_multipart_uploads_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_upload_id_fkey" FOREIGN KEY ("upload_id") REFERENCES "storage"."s3_multipart_uploads"("id") ON DELETE CASCADE;



ALTER TABLE "auth"."audit_log_entries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."flow_state" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."identities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."instances" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."mfa_amr_claims" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."mfa_challenges" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."mfa_factors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."one_time_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."refresh_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."saml_providers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."saml_relay_states" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."schema_migrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."sso_domains" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."sso_providers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "auth"."users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "Enable delete for users based on user_id" ON "public"."comments" FOR DELETE TO "authenticated" USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."diaries_follows" FOR DELETE USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."events" FOR DELETE USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."favorites" FOR DELETE USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."follows" FOR DELETE TO "authenticated" USING (("follower_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."notifications" FOR DELETE USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."posts" FOR DELETE USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."questions" FOR DELETE USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."user_feed" FOR DELETE USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."user_views" FOR DELETE USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable insert for authenticated users only" ON "public"."comments" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."diaries" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."diaries_follows" FOR INSERT WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."events" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."favorites" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."follows" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."notifications" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."posts" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."questions" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."topics" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."user_feed" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."user_views" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."weeks" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for users based on user_id" ON "public"."profiles" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "uid"));



CREATE POLICY "Enable read access for all users" ON "public"."comments" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."diaries" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."diaries_follows" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."events" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."favorites" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."follows" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."notifications" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."posts" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."questions" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."recommended_feed" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."topics" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."weeks" FOR SELECT USING (true);



CREATE POLICY "Enable update for users based on email" ON "public"."comments" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."diaries" FOR UPDATE TO "authenticated" USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."diaries_follows" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."events" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."favorites" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."notifications" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."posts" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."questions" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."user_feed" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on email" ON "public"."user_views" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Enable update for users based on user id" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "uid")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "uid"));



CREATE POLICY "Enable update for users based on user_id" ON "public"."weeks" FOR UPDATE USING (("user_id" = "public"."get_legacy_user_id"())) WITH CHECK (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Only own" ON "public"."user_views" FOR SELECT USING (("user_id" = "public"."get_legacy_user_id"()));



CREATE POLICY "Only users own feed" ON "public"."user_feed" FOR SELECT TO "authenticated" USING (("user_id" = "public"."get_legacy_user_id"()));



ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."diaries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."diaries_follows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."favorites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."follows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."posts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."questions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recommended_feed" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."topics" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_feed" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_views" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."weeks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "Give users access to own folder 1fxut1m_0" ON "storage"."objects" FOR SELECT USING (true);



CREATE POLICY "Give users access to own folder 1fxut1m_1" ON "storage"."objects" FOR INSERT WITH CHECK ((("bucket_id" = 'profilePhotos'::"text") AND (( SELECT ("profiles"."id")::"text" AS "id"
   FROM "public"."profiles"
  WHERE ("profiles"."uid" = "auth"."uid"())) = ("storage"."foldername"("name"))[1])));



CREATE POLICY "Give users access to own folder 1fxut1m_2" ON "storage"."objects" FOR UPDATE USING ((("bucket_id" = 'profilePhotos'::"text") AND (( SELECT ("auth"."uid"())::"text" AS "uid") = ("storage"."foldername"("name"))[1])));



CREATE POLICY "Give users access to own folder 1fxut1m_3" ON "storage"."objects" FOR DELETE USING ((("bucket_id" = 'profilePhotos'::"text") AND (( SELECT ("auth"."uid"())::"text" AS "uid") = ("storage"."foldername"("name"))[1])));



CREATE POLICY "Give users access to own folder 2558r_0" ON "storage"."objects" FOR INSERT WITH CHECK ((("bucket_id" = 'user'::"text") AND (( SELECT ("public"."get_legacy_user_id"())::"text" AS "get_legacy_user_id") = ("storage"."foldername"("name"))[1])));



CREATE POLICY "Give users access to own folder 2558r_1" ON "storage"."objects" FOR UPDATE USING ((("bucket_id" = 'user'::"text") AND (( SELECT ("public"."get_legacy_user_id"())::"text" AS "get_legacy_user_id") = ("storage"."foldername"("name"))[1])));



CREATE POLICY "Give users access to own folder 2558r_2" ON "storage"."objects" FOR DELETE USING ((("bucket_id" = 'user'::"text") AND (( SELECT ("public"."get_legacy_user_id"())::"text" AS "get_legacy_user_id") = ("storage"."foldername"("name"))[1])));



ALTER TABLE "storage"."buckets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."migrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."objects" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."s3_multipart_uploads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."s3_multipart_uploads_parts" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "auth" TO "anon";
GRANT USAGE ON SCHEMA "auth" TO "authenticated";
GRANT USAGE ON SCHEMA "auth" TO "service_role";
GRANT ALL ON SCHEMA "auth" TO "supabase_auth_admin";
GRANT ALL ON SCHEMA "auth" TO "dashboard_user";
GRANT USAGE ON SCHEMA "auth" TO "postgres";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT USAGE ON SCHEMA "storage" TO "postgres";
GRANT USAGE ON SCHEMA "storage" TO "anon";
GRANT USAGE ON SCHEMA "storage" TO "authenticated";
GRANT USAGE ON SCHEMA "storage" TO "service_role";
GRANT ALL ON SCHEMA "storage" TO "supabase_storage_admin";
GRANT ALL ON SCHEMA "storage" TO "dashboard_user";



GRANT ALL ON FUNCTION "auth"."email"() TO "dashboard_user";
GRANT ALL ON FUNCTION "auth"."email"() TO "postgres";



GRANT ALL ON FUNCTION "auth"."jwt"() TO "postgres";
GRANT ALL ON FUNCTION "auth"."jwt"() TO "dashboard_user";



GRANT ALL ON FUNCTION "auth"."role"() TO "dashboard_user";
GRANT ALL ON FUNCTION "auth"."role"() TO "postgres";



GRANT ALL ON FUNCTION "auth"."uid"() TO "dashboard_user";
GRANT ALL ON FUNCTION "auth"."uid"() TO "postgres";



GRANT ALL ON PROCEDURE "public"."archive_user_views"() TO "anon";
GRANT ALL ON PROCEDURE "public"."archive_user_views"() TO "authenticated";
GRANT ALL ON PROCEDURE "public"."archive_user_views"() TO "service_role";



GRANT ALL ON FUNCTION "public"."count_likes"("user_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."count_likes"("user_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."count_likes"("user_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_user_profile"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_user_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_user_profile"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fetch_user_feed"("user_id" integer, "seen_post_ids" integer[], "page_number" integer, "page_size" integer, "include_stories" boolean, "only_stories" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."fetch_user_feed"("user_id" integer, "seen_post_ids" integer[], "page_number" integer, "page_size" integer, "include_stories" boolean, "only_stories" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fetch_user_feed"("user_id" integer, "seen_post_ids" integer[], "page_number" integer, "page_size" integer, "include_stories" boolean, "only_stories" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_legacy_user_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_legacy_user_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_legacy_user_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_post"("post_id" integer, "name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_post"("post_id" integer, "name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_post"("post_id" integer, "name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_post_by_name"("name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_post_by_name"("name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_post_by_name"("name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_data"("username" "text", "user_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_data"("username" "text", "user_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_data"("username" "text", "user_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_feed"("user_id" integer, "seen_post_ids" integer[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_feed"("user_id" integer, "seen_post_ids" integer[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_feed"("user_id" integer, "seen_post_ids" integer[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_meta_user_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_meta_user_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_meta_user_id"() TO "service_role";



GRANT ALL ON PROCEDURE "public"."mark_posts_seen"(IN "seen_user_id" integer, IN "post_ids" integer[]) TO "anon";
GRANT ALL ON PROCEDURE "public"."mark_posts_seen"(IN "seen_user_id" integer, IN "post_ids" integer[]) TO "authenticated";
GRANT ALL ON PROCEDURE "public"."mark_posts_seen"(IN "seen_user_id" integer, IN "post_ids" integer[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."populate_feed"("user_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."populate_feed"("user_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."populate_feed"("user_id" integer) TO "service_role";



GRANT ALL ON PROCEDURE "public"."populate_recommended_feed"() TO "anon";
GRANT ALL ON PROCEDURE "public"."populate_recommended_feed"() TO "authenticated";
GRANT ALL ON PROCEDURE "public"."populate_recommended_feed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."populate_user_feed"("user_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."populate_user_feed"("user_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."populate_user_feed"("user_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."recommend_feed"("user_id" integer, "seen_post_ids" integer[], "page_number" integer, "page_size" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."recommend_feed"("user_id" integer, "seen_post_ids" integer[], "page_number" integer, "page_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."recommend_feed"("user_id" integer, "seen_post_ids" integer[], "page_number" integer, "page_size" integer) TO "service_role";



GRANT ALL ON PROCEDURE "public"."reset_user_views"(IN "user_id" integer) TO "anon";
GRANT ALL ON PROCEDURE "public"."reset_user_views"(IN "user_id" integer) TO "authenticated";
GRANT ALL ON PROCEDURE "public"."reset_user_views"(IN "user_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_posts_seen"("post_ids" integer[]) TO "anon";
GRANT ALL ON FUNCTION "public"."set_posts_seen"("post_ids" integer[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_posts_seen"("post_ids" integer[]) TO "service_role";



GRANT ALL ON FUNCTION "storage"."can_insert_object"("bucketid" "text", "name" "text", "owner" "uuid", "metadata" "jsonb") TO "postgres";



GRANT ALL ON FUNCTION "storage"."extension"("name" "text") TO "postgres";



GRANT ALL ON FUNCTION "storage"."filename"("name" "text") TO "postgres";



GRANT ALL ON FUNCTION "storage"."foldername"("name" "text") TO "postgres";



GRANT ALL ON FUNCTION "storage"."get_size_by_bucket"() TO "postgres";



GRANT ALL ON FUNCTION "storage"."list_multipart_uploads_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer, "next_key_token" "text", "next_upload_token" "text") TO "postgres";



GRANT ALL ON FUNCTION "storage"."list_objects_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer, "start_after" "text", "next_token" "text") TO "postgres";



GRANT ALL ON FUNCTION "storage"."operation"() TO "postgres";



GRANT ALL ON FUNCTION "storage"."search"("prefix" "text", "bucketname" "text", "limits" integer, "levels" integer, "offsets" integer, "search" "text", "sortcolumn" "text", "sortorder" "text") TO "postgres";



GRANT ALL ON FUNCTION "storage"."update_updated_at_column"() TO "postgres";



GRANT ALL ON TABLE "auth"."audit_log_entries" TO "dashboard_user";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."audit_log_entries" TO "postgres";
GRANT SELECT ON TABLE "auth"."audit_log_entries" TO "postgres" WITH GRANT OPTION;



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."flow_state" TO "postgres";
GRANT SELECT ON TABLE "auth"."flow_state" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."flow_state" TO "dashboard_user";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."identities" TO "postgres";
GRANT SELECT ON TABLE "auth"."identities" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."identities" TO "dashboard_user";



GRANT ALL ON TABLE "auth"."instances" TO "dashboard_user";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."instances" TO "postgres";
GRANT SELECT ON TABLE "auth"."instances" TO "postgres" WITH GRANT OPTION;



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."mfa_amr_claims" TO "postgres";
GRANT SELECT ON TABLE "auth"."mfa_amr_claims" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."mfa_amr_claims" TO "dashboard_user";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."mfa_challenges" TO "postgres";
GRANT SELECT ON TABLE "auth"."mfa_challenges" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."mfa_challenges" TO "dashboard_user";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."mfa_factors" TO "postgres";
GRANT SELECT ON TABLE "auth"."mfa_factors" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."mfa_factors" TO "dashboard_user";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."one_time_tokens" TO "postgres";
GRANT SELECT ON TABLE "auth"."one_time_tokens" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."one_time_tokens" TO "dashboard_user";



GRANT ALL ON TABLE "auth"."refresh_tokens" TO "dashboard_user";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."refresh_tokens" TO "postgres";
GRANT SELECT ON TABLE "auth"."refresh_tokens" TO "postgres" WITH GRANT OPTION;



GRANT ALL ON SEQUENCE "auth"."refresh_tokens_id_seq" TO "dashboard_user";
GRANT ALL ON SEQUENCE "auth"."refresh_tokens_id_seq" TO "postgres";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."saml_providers" TO "postgres";
GRANT SELECT ON TABLE "auth"."saml_providers" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."saml_providers" TO "dashboard_user";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."saml_relay_states" TO "postgres";
GRANT SELECT ON TABLE "auth"."saml_relay_states" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."saml_relay_states" TO "dashboard_user";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."sessions" TO "postgres";
GRANT SELECT ON TABLE "auth"."sessions" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."sessions" TO "dashboard_user";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."sso_domains" TO "postgres";
GRANT SELECT ON TABLE "auth"."sso_domains" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."sso_domains" TO "dashboard_user";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."sso_providers" TO "postgres";
GRANT SELECT ON TABLE "auth"."sso_providers" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "auth"."sso_providers" TO "dashboard_user";



GRANT ALL ON TABLE "auth"."users" TO "dashboard_user";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "auth"."users" TO "postgres";
GRANT SELECT ON TABLE "auth"."users" TO "postgres" WITH GRANT OPTION;
GRANT SELECT ON TABLE "auth"."users" TO "authenticated";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."diaries" TO "anon";
GRANT ALL ON TABLE "public"."diaries" TO "authenticated";
GRANT ALL ON TABLE "public"."diaries" TO "service_role";



GRANT ALL ON TABLE "public"."diaries_follows" TO "anon";
GRANT ALL ON TABLE "public"."diaries_follows" TO "authenticated";
GRANT ALL ON TABLE "public"."diaries_follows" TO "service_role";



GRANT ALL ON SEQUENCE "public"."diaries_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."diaries_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."diaries_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."diaries_subscribers_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."diaries_subscribers_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."diaries_subscribers_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."events_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."favorites" TO "anon";
GRANT ALL ON TABLE "public"."favorites" TO "authenticated";
GRANT ALL ON TABLE "public"."favorites" TO "service_role";



GRANT ALL ON TABLE "public"."follows" TO "anon";
GRANT ALL ON TABLE "public"."follows" TO "authenticated";
GRANT ALL ON TABLE "public"."follows" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."posts" TO "anon";
GRANT ALL ON TABLE "public"."posts" TO "authenticated";
GRANT ALL ON TABLE "public"."posts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."posts_follows_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."posts_follows_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."posts_follows_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."posts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."posts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."posts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."questions" TO "anon";
GRANT ALL ON TABLE "public"."questions" TO "authenticated";
GRANT ALL ON TABLE "public"."questions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."questions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."questions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."questions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."recommended_feed" TO "anon";
GRANT ALL ON TABLE "public"."recommended_feed" TO "authenticated";
GRANT ALL ON TABLE "public"."recommended_feed" TO "service_role";



GRANT ALL ON TABLE "public"."topics" TO "anon";
GRANT ALL ON TABLE "public"."topics" TO "authenticated";
GRANT ALL ON TABLE "public"."topics" TO "service_role";



GRANT ALL ON TABLE "public"."user_feed" TO "anon";
GRANT ALL ON TABLE "public"."user_feed" TO "authenticated";
GRANT ALL ON TABLE "public"."user_feed" TO "service_role";



GRANT ALL ON TABLE "public"."user_views" TO "anon";
GRANT ALL ON TABLE "public"."user_views" TO "authenticated";
GRANT ALL ON TABLE "public"."user_views" TO "service_role";



GRANT ALL ON TABLE "public"."user_views_archive" TO "anon";
GRANT ALL ON TABLE "public"."user_views_archive" TO "authenticated";
GRANT ALL ON TABLE "public"."user_views_archive" TO "service_role";



GRANT ALL ON SEQUENCE "public"."users_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."users_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."users_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."weeks" TO "anon";
GRANT ALL ON TABLE "public"."weeks" TO "authenticated";
GRANT ALL ON TABLE "public"."weeks" TO "service_role";



GRANT ALL ON SEQUENCE "public"."weeks_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."weeks_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."weeks_id_seq" TO "service_role";



GRANT ALL ON TABLE "storage"."buckets" TO "anon";
GRANT ALL ON TABLE "storage"."buckets" TO "authenticated";
GRANT ALL ON TABLE "storage"."buckets" TO "service_role";
GRANT ALL ON TABLE "storage"."buckets" TO "postgres";



GRANT ALL ON TABLE "storage"."objects" TO "anon";
GRANT ALL ON TABLE "storage"."objects" TO "authenticated";
GRANT ALL ON TABLE "storage"."objects" TO "service_role";
GRANT ALL ON TABLE "storage"."objects" TO "postgres";



GRANT ALL ON TABLE "storage"."s3_multipart_uploads" TO "service_role";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads" TO "authenticated";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads" TO "anon";
GRANT ALL ON TABLE "storage"."s3_multipart_uploads" TO "postgres";



GRANT ALL ON TABLE "storage"."s3_multipart_uploads_parts" TO "service_role";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads_parts" TO "authenticated";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads_parts" TO "anon";
GRANT ALL ON TABLE "storage"."s3_multipart_uploads_parts" TO "postgres";



ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_auth_admin" IN SCHEMA "auth" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_auth_admin" IN SCHEMA "auth" GRANT ALL ON SEQUENCES  TO "dashboard_user";



ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_auth_admin" IN SCHEMA "auth" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_auth_admin" IN SCHEMA "auth" GRANT ALL ON FUNCTIONS  TO "dashboard_user";



ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_auth_admin" IN SCHEMA "auth" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_auth_admin" IN SCHEMA "auth" GRANT ALL ON TABLES  TO "dashboard_user";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES  TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS  TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES  TO "service_role";



RESET ALL;

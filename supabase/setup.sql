-- 匯聚洋流 The Taiwan Current — 資料庫建置
-- 用法：Supabase 後台 → SQL Editor → New query → 貼上全部 → Run。只需要跑一次。

-- ============ 1. 正規化（比對重複句用：去掉空白、標點、大小寫）============
create or replace function public.line_norm(t text) returns text
language sql immutable as $$
  select regexp_replace(lower(t), '[[:space:][:punct:]　，。！？、；：「」『』（）《》〈〉…—～・．｡､‧]+', '', 'g')
$$;

-- ============ 2. 表 ============
-- lines：每句話一列。status：curated 精選／public 公開／review 待審／hidden 隱藏
create table if not exists public.lines (
  id         bigint generated always as identity primary key,
  text       text not null check (char_length(btrim(text)) between 1 and 20),
  norm       text generated always as (public.line_norm(text)) stored,
  status     text not null default 'public' check (status in ('curated','public','review','hidden')),
  source     text not null default 'game'   check (source in ('game','threads','dm','seed')),
  people     integer not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists lines_norm_key on public.lines(norm);

-- picks：每台設備選了哪一句（同一台設備只有一列，再送就改這列）
create table if not exists public.picks (
  device     text primary key,
  line_id    bigint not null references public.lines(id) on delete cascade,
  updated_at timestamptz not null default now()
);
create index if not exists picks_line_idx on public.picks(line_id);
create index if not exists picks_time_idx on public.picks(updated_at);

-- filter_words：kind = block 直接拒收／review 收下但先待審；is_regex = true 時 word 當正規表示式
create table if not exists public.filter_words (
  word     text primary key,
  kind     text not null check (kind in ('block','review')),
  is_regex boolean not null default false
);

-- ============ 3. 人數自動更新 ============
create or replace function public.picks_count() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    update public.lines set people = (select count(*) from public.picks where line_id = old.line_id) where id = old.line_id;
  end if;
  if tg_op in ('INSERT','UPDATE') then
    update public.lines set people = (select count(*) from public.picks where line_id = new.line_id) where id = new.line_id;
  end if;
  return null;
end $$;
drop trigger if exists picks_count on public.picks;
create trigger picks_count after insert or update or delete on public.picks
  for each row execute function public.picks_count();

-- ============ 4. 關鍵字判斷 ============
create or replace function public.line_flag(t text) returns text
language sql stable security definer set search_path = '' as $$
  select w.kind from public.filter_words w
  where case when w.is_regex then t ~* w.word
             else strpos(lower(regexp_replace(t, '\s', '', 'g')), lower(w.word)) > 0 end
  order by case w.kind when 'block' then 0 else 1 end
  limit 1
$$;

-- ============ 4b. 投票日（台北時間 2026-11-28 整天）============
create or replace function public.is_eday() returns boolean
language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Taipei')::date = date '2026-11-28'
$$;

-- ============ 5. 送出一句 ============
-- 回傳 {ok:true} 或 {ok:false, reason: closed|device|length|busy|blocked}
create or replace function public.submit_line(p_text text, p_device text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  t text := btrim(coalesce(p_text, ''));
  n text; lid bigint; old_id bigint; flag text;
begin
  if public.is_eday() then return json_build_object('ok', false, 'reason', 'closed'); end if;
  if p_device is null or p_device !~ '^[A-Za-z0-9-]{8,64}$' then
    return json_build_object('ok', false, 'reason', 'device'); end if;
  if char_length(t) < 1 or char_length(t) > 20 then
    return json_build_object('ok', false, 'reason', 'length'); end if;
  n := public.line_norm(t);
  if n = '' then return json_build_object('ok', false, 'reason', 'length'); end if;

  select line_id into old_id from public.picks where device = p_device;
  select id into lid from public.lines where norm = n;
  if lid is not null and lid = old_id then return json_build_object('ok', true); end if;

  if (select count(*) from public.picks where updated_at > now() - interval '1 minute') >= 30 then
    return json_build_object('ok', false, 'reason', 'busy'); end if;

  if lid is null then
    flag := public.line_flag(t);
    if flag = 'block' then return json_build_object('ok', false, 'reason', 'blocked'); end if;
    insert into public.lines(text, status, source)
      values (t, case when flag = 'review' then 'review' else 'public' end, 'game')
      on conflict (norm) do nothing
      returning id into lid;
    if lid is null then select id into lid from public.lines where norm = n; end if;
  end if;

  insert into public.picks(device, line_id) values (p_device, lid)
    on conflict (device) do update set line_id = excluded.line_id, updated_at = now();

  -- 改寫後，舊句若沒人再選、又是玩家句且沒被你精選，就清掉
  if old_id is not null and old_id <> lid then
    delete from public.lines l where l.id = old_id and l.source = 'game'
      and l.status in ('public','review')
      and not exists (select 1 from public.picks p where p.line_id = old_id);
  end if;
  return json_build_object('ok', true);
end $$;

-- ============ 6. 拿一包台詞 ============
-- curated：精選隨機最多 80；players：公開玩家句，最新 20 + 其餘隨機 20
-- 投票日：只給精選、拿掉含「投票／票／十一月二十八／11/28」的，players 為空，closed = true
create or replace function public.get_lines() returns json
language plpgsql stable security definer set search_path = '' as $$
declare e boolean := public.is_eday();
begin
  if e then
    return json_build_object('closed', true, 'players', '[]'::json,
      'curated', coalesce((select json_agg(text) from (select text from public.lines
        where status = 'curated' and text !~ '投票|票|十一月二十八|11/28' order by random() limit 80) c), '[]'::json));
  end if;
  return (with cur as (select text from public.lines where status = 'curated' order by random() limit 80),
       rec as (select id, text from public.lines where status = 'public' order by created_at desc limit 20),
       rnd as (select text from public.lines where status = 'public' and id not in (select id from rec)
               order by random() limit 20)
  select json_build_object('closed', false,
    'curated', coalesce((select json_agg(text) from cur), '[]'::json),
    'players', coalesce((select json_agg(text) from (select text from rec union all select text from rnd) p), '[]'::json)));
end $$;

-- ============ 7. 權限：訪客碰不到表，只能呼叫兩個功能 ============
alter table public.lines        enable row level security;
alter table public.picks        enable row level security;
alter table public.filter_words enable row level security;
revoke all on public.lines, public.picks, public.filter_words from anon, authenticated;
revoke all on function public.submit_line(text, text), public.get_lines(),
              public.line_flag(text), public.picks_count(), public.is_eday() from public, anon, authenticated;
grant execute on function public.submit_line(text, text), public.get_lines() to anon, authenticated;

-- ============ 8. 初始資料（重跑會整批換新；玩家句不動）============
-- 精選句：換成這一版；舊的 seed 精選若不在清單內就刪掉
delete from public.lines where source = 'seed' and text not in (
  '我也以為只有我在乎。',
  '原來你也在這裡。',
  '我從南部上來，我會返鄉投票。',
  '我希望巷口的公園多一點樹。',
  '我不太會講道理，但我想站出來。',
  '第一次投票，有點緊張。',
  '我在國外，這次飛回來。',
  '我不認識你，但我們往同一個方向。',
  '小水滴推不動什麼，可是我們不只一滴水。',
  '我以為大家都放棄了。',
  '我想讓我的孩子在這裡長大。',
  '我爸媽跟我意見不一樣，但我們都愛這裡。',
  '下班好累，但還是想做點什麼。',
  '這座城市對我很好，我想對它好一點。',
  '我跟你一樣，猶豫了很久。',
  '我只是想被聽見。',
  '慢一點沒關係，我們一起漂。',
  '我住在這裡好幾年了，還算外地人嗎？',
  '我想要的不多，只是更好一點的日常。',
  '我把話傳給家裡的長輩了。',
  '我不喜歡吵架，所以用投票說話。',
  '暖的不是水，是身旁有人。',
  '一起，就不怕被沖散。',
  '我不確定會不會改變什麼，但我想試試。',
  '我曾經很冷漠，但這次我決定不再沉默。',
  '我們會流到哪裡呢？',
  '回頭看，好多人。',
  '十一月二十八日，見。'
);
insert into public.lines(text, status, source) values
  ('我也以為只有我在乎。', 'curated', 'seed'),
  ('原來你也在這裡。', 'curated', 'seed'),
  ('我從南部上來，我會返鄉投票。', 'curated', 'seed'),
  ('我希望巷口的公園多一點樹。', 'curated', 'seed'),
  ('我不太會講道理，但我想站出來。', 'curated', 'seed'),
  ('第一次投票，有點緊張。', 'curated', 'seed'),
  ('我在國外，這次飛回來。', 'curated', 'seed'),
  ('我不認識你，但我們往同一個方向。', 'curated', 'seed'),
  ('小水滴推不動什麼，可是我們不只一滴水。', 'curated', 'seed'),
  ('我以為大家都放棄了。', 'curated', 'seed'),
  ('我想讓我的孩子在這裡長大。', 'curated', 'seed'),
  ('我爸媽跟我意見不一樣，但我們都愛這裡。', 'curated', 'seed'),
  ('下班好累，但還是想做點什麼。', 'curated', 'seed'),
  ('這座城市對我很好，我想對它好一點。', 'curated', 'seed'),
  ('我跟你一樣，猶豫了很久。', 'curated', 'seed'),
  ('我只是想被聽見。', 'curated', 'seed'),
  ('慢一點沒關係，我們一起漂。', 'curated', 'seed'),
  ('我住在這裡好幾年了，還算外地人嗎？', 'curated', 'seed'),
  ('我想要的不多，只是更好一點的日常。', 'curated', 'seed'),
  ('我把話傳給家裡的長輩了。', 'curated', 'seed'),
  ('我不喜歡吵架，所以用投票說話。', 'curated', 'seed'),
  ('暖的不是水，是身旁有人。', 'curated', 'seed'),
  ('一起，就不怕被沖散。', 'curated', 'seed'),
  ('我不確定會不會改變什麼，但我想試試。', 'curated', 'seed'),
  ('我曾經很冷漠，但這次我決定不再沉默。', 'curated', 'seed'),
  ('我們會流到哪裡呢？', 'curated', 'seed'),
  ('回頭看，好多人。', 'curated', 'seed'),
  ('十一月二十八日，見。', 'curated', 'seed')
on conflict (norm) do update set status = 'curated', source = 'seed', text = excluded.text;

-- 關鍵字：整批換新
delete from public.filter_words;

-- block 直接拒收：髒話與人身攻擊、族群／政治蔑稱、暴力字
insert into public.filter_words(word, kind, is_regex) values
  ('靠北', 'block', false),
  ('靠杯', 'block', false),
  ('操你', 'block', false),
  ('雞掰', 'block', false),
  ('機掰', 'block', false),
  ('白痴', 'block', false),
  ('白癡', 'block', false),
  ('智障', 'block', false),
  ('去死', 'block', false),
  ('垃圾', 'block', false),
  ('廢物', 'block', false),
  ('屁眼', 'block', false),
  ('低能', 'block', false),
  ('腦殘', 'block', false),
  ('畜生', 'block', false),
  ('畜牲', 'block', false),
  ('支那', 'block', false),
  ('綠蛆', 'block', false),
  ('藍蛆', 'block', false),
  ('塔綠班', 'block', false),
  ('賣台', 'block', false),
  ('共匪', 'block', false),
  ('滾回', 'block', false),
  ('fuck', 'block', false),
  ('shit', 'block', false),
  ('bitch', 'block', false),
  ('dick', 'block', false),
  ('cunt', 'block', false),
  ('nmsl', 'block', false),
  ('死全家', 'block', false),
  ('https?://', 'block', true),
  ('www\.', 'block', true),
  ('\.(com|tw|net|org|cc|me|io)\y', 'block', true),
  ('\d{5,}', 'block', true),
  ('@', 'block', true),
  ('line\s*id', 'block', true)
on conflict (word) do nothing;

-- review 待審：單字（避免誤擋樹幹、殺價）、其他政治人物名、政黨名、罷免
-- 沈伯洋、拉票用語（投給、凍蒜…）不在名單內＝直接公開
insert into public.filter_words(word, kind, is_regex) values
  ('幹', 'review', false),
  ('殺', 'review', false),
  ('賤', 'review', false),
  ('婊', 'review', false),
  ('屌', 'review', false),
  ('蔣萬安', 'review', false),
  ('萬安', 'review', false),
  ('柯文哲', 'review', false),
  ('黃國昌', 'review', false),
  ('賴清德', 'review', false),
  ('鄭麗文', 'review', false),
  ('侯友宜', 'review', false),
  ('韓國瑜', 'review', false),
  ('蔡英文', 'review', false),
  ('朱立倫', 'review', false),
  ('盧秀燕', 'review', false),
  ('習近平', 'review', false),
  ('民進黨', 'review', false),
  ('國民黨', 'review', false),
  ('民眾黨', 'review', false),
  ('時代力量', 'review', false),
  ('共產黨', 'review', false),
  ('中共', 'review', false),
  ('罷免', 'review', false)
on conflict (word) do nothing;

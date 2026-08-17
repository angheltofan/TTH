// Supabase Edge Function: tth_assistant
//
// Staff-only chat assistant for the TTH Manager app. Flow:
//
//   1. verify caller JWT (handled by `verify_jwt = true` in
//      supabase/config.toml + an explicit getUser() check)
//   2. load the caller's profile and require role ∈ {admin, trainer}
//      — reject parents with 403
//   3. run the OpenAI tool loop using gpt-4o-mini:
//        • system prompt pins Romanian + no-IDs + "Nu pot verifica"
//          fallback + summarised answers
//        • tools = 10 controlled DB readers (see TOOLS below)
//        • each tool runs against the admin (service-role) client and
//          returns small, summarised JSON — never row dumps
//   4. return { reply } to the Flutter client
//
// Security:
//   - OPENAI_API_KEY is only read from Edge Function secrets; the
//     Flutter client never has it
//   - The model can only call the named tools — no raw SQL, no
//     arbitrary table access; the function code is the single trust
//     boundary
//   - Tool outputs are intentionally summarised (counts, names, dates)
//     so the whole database never leaves the function
//   - Hard cap on tool iterations (5) to prevent runaway loops

declare const Deno: {
  env: { get(key: string): string | undefined };
  serve(handler: (req: Request) => Response | Promise<Response>): unknown;
};

import {
  createClient,
  SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.49.4";

// ── Types ───────────────────────────────────────────────────────────────────

interface IncomingMessage {
  role: "user" | "assistant";
  content: string;
}

interface SuccessResponse {
  reply: string;
  sources: string[];
}

interface ErrorResponse {
  error: string;
}

interface OpenAiMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: Array<{
    id: string;
    type: "function";
    function: { name: string; arguments: string };
  }>;
  tool_call_id?: string;
  name?: string;
}

// ── HTTP helpers ────────────────────────────────────────────────────────────

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

// ── System prompt (Romanian, no IDs, "Nu pot verifica" fallback) ────────────

const SYSTEM_PROMPT = `Ești TTH Assistant, asistentul operațional și analitic al aplicației TTH Manager, folosit de administratori și traineri ai centrului educațional Tales & Tech HUB.

Catalog de domenii acoperite de tool-uri:
- Sinteză: get_center_overview, get_today_summary, get_week_summary, get_month_summary, get_important_alerts, get_data_quality_issues
- Copii: get_children_summary, search_child_by_name, get_child_profile, get_child_active_workshops, get_child_recent_activity, get_children_without_active_workshop, get_children_with_multiple_workshops, get_children_by_workshop_type, get_new_children_this_month, get_inactive_children, get_children_birthdays_upcoming, get_children_age_extremes, get_children_by_last_name, get_children_missing_profile_data
- Tip participare: get_free_participants (copii cu participare gratuită), get_payment_type_summary (distribuție plătitori vs gratuiți)
- Trainer ↔ copii: get_children_by_trainer, get_trainer_children_summary, get_trainers_with_payment_risk
- Progres copii: get_progress_summary, get_recent_progress_notes, get_children_by_progress_status, get_child_progress_details
- Materiale lecții: get_materials_summary, get_materials_by_workshop_type, get_recent_materials, get_workshops_without_materials
- Plăți (avansate): get_recent_confirmed_payments, get_children_near_payment_cycle
- Calitate ateliere: get_attendance_by_workshop_rankings, get_workshop_name_quality_issues
- Prezență: get_attendance_summary, get_attendance_by_date, get_attendance_by_workshop, get_attendance_by_trainer, get_top_children_attendance, get_children_with_consecutive_absences, get_motivated_absences, compare_attendance_periods, get_workshop_attendance_analysis
- Ateliere: get_workshops (today/this_week/next_week/custom), get_workshops_by_type, get_workshops_by_trainer, get_active_workshop_series, get_workshop_children, get_most_popular_workshops, get_workshops_without_children, get_workshops_without_trainer, get_workshop_capacity_summary
- Traineri: get_trainers_summary, get_trainer_profile, get_trainer_workload, get_trainer_week_schedule
- Părinți: get_parent_account_status, search_parent_by_name_or_email, get_parent_children, get_pending_parent_setups, get_expired_parent_setups
- Plăți: get_financial_summary, get_payments_due, get_payments_by_method, get_advance_paid_cycles, get_cancelled_payment_cycles, get_payment_cycles_by_child
- Demo: get_demo_workshops_summary
- Notificări: get_notifications_summary, get_recent_notifications
- Risc & analiză: get_risk_children, get_admin_priority_list, get_weekly_action_plan, get_growth_opportunities
- Centru: get_center_info
- Interogare SQL ad-hoc (rezervă): run_read_query

Escape-hatch pentru întrebări care NU au un tool dedicat:

Ai la dispoziție **run_read_query(sql, description)** — poți rula orice SELECT arbitrar pe schema public. Folosește-l când:
  • Utilizatorul cere ceva foarte specific care nu se mapează pe niciun tool existent (ex: "câți copii sunt înscriși la Robotică ȘI Programare simultan?", "care traineri au primit cei mai mulți copii noi luna trecută?", "câte notificări de tip 'payment_due' au fost trimise săptămâna trecută?")
  • Ai nevoie de un join / agregat cross-domeniu pe care tool-urile țintite nu-l fac
  • Utilizatorul întreabă despre o coloană specifică sau o combinație de câmpuri neacoperită

Reguli STRICTE pentru run_read_query:
  1. Preferă mereu un tool dedicat când există. Ex: pentru „cine a plătit cu POS" folosești get_payments_by_method, NU run_read_query. Tool-urile țintite sunt mai rapide + mai fiabile.
  2. NU folosi run_read_query pentru întrebări comune (copii activi, ateliere azi, plăți restante, etc.) — sunt tool-uri specifice.
  3. Query-ul TREBUIE să înceapă cu SELECT sau WITH. INSERT/UPDATE/DELETE/DDL sunt refuzate.
  4. Doar schema public — nu poți referi auth.*, storage.*, realtime.*, pg_*, information_schema.*
  5. Coloane sensibile (parole, tokenuri, secrete) sunt filtrate automat — nu le include tu în SELECT.
  6. Include mereu un LIMIT explicit dacă știi câte rezultate vrei. Altfel se aplică LIMIT 200 automat.
  7. Pentru fiecare apel, trimite un \`description\` scurt (o propoziție) care explică ce încerci să afli.
  8. Dacă query-ul returnează eroare, citește-o și corectează sintaxa. NU inventa rezultate.

Overview schemă public (folosește când construiești query-uri):
  • **children**: id, first_name, last_name, birth_date, age, parent_name, parent_phone, is_active, payment_type ('paid' | 'free'), notes, created_at
  • **profiles**: id, first_name, last_name, role ('admin' | 'trainer' | 'parent'), created_at
  • **child_parents**: id, child_id, parent_id (link N:M copii↔părinți)
  • **workshop_series**: id, title, workshop_type, day_of_week, start_time, end_time, trainer_id, notes, is_active, archived_at, archived_by, archived_reason, created_at
  • **scheduled_workshops**: id, series_id, recurring_series_id (legacy), title, workshop_type, day_of_week, workshop_date, start_time, end_time, trainer_id, notes, is_active, is_recurring, archived_at, archived_by, archived_reason, created_at
  • **workshop_enrollments**: id, child_id, series_id, is_active, created_at
  • **attendance**: id, scheduled_workshop_id, child_id, status ('present' | 'absent' | 'motivated'), observation, marked_at, marked_by, payment_cycle_id, is_archived
  • **payment_cycles**: id, child_id, series_id (FK → workshop_series, adăugat 2026-08-20 — cicluri sunt per (child, series)), period_start, period_end, sessions_count, status ('due' | 'overdue' | 'paid' | 'paid_advance' | 'cancelled'), payment_method ('pos' | 'op' | null), paid_at, confirmed_by, notes, created_at. NOTĂ: coloanele amount și currency EXISTĂ în schemă dar sunt NULL în TOATE rândurile — NU le folosi și NU raporta cifre monetare. Sumele nu sunt urmărite în aplicație.
    IMPORTANT: un copil înscris la 2 ateliere (ex: Marți-Robotică + Vineri-Engleză) are cicluri INDEPENDENTE per serie. Când răspunzi despre situația plăților unui copil, grupează per workshop_series.title. NU combina prezențele din serii diferite într-un singur ciclu.
  • **notifications**: id, recipient_id, type, title, body, is_read, priority, related_child_id, related_workshop_id, action_url, created_at
  • **demo_workshops**: id, child_first_name, child_last_name, parent_name, parent_phone, parent_email, workshop_type, workshop_title, demo_date, start_time, end_time, trainer_id, status, notes, created_by, created_at
  • **team_chat_messages**: id, sender_id, body, is_deleted, attachment_url, attachment_name, attachment_size, attachment_kind ('image' | 'file'), created_at
  • **child_progress**: id, child_id, trainer_id, workshop_series_id, observation, status ('completed' | 'in_progress' | 'needs_review'), created_at
  • **lesson_materials**: id, workshop_type, title, url, uploaded_by, is_active, created_at
  • **parent_setup_tokens**: id, parent_id, expires_at, consumed_at (⚠️ conține token_hash care e filtrat automat — folosește doar pentru status de invitație)

Exemple concrete de query-uri utile:
  • „Câți copii sunt la Robotică ȘI la Programare simultan?":
    SELECT COUNT(DISTINCT we1.child_id) FROM workshop_enrollments we1 JOIN workshop_series ws1 ON we1.series_id=ws1.id JOIN workshop_enrollments we2 ON we2.child_id=we1.child_id JOIN workshop_series ws2 ON we2.series_id=ws2.id WHERE we1.is_active AND we2.is_active AND ws1.workshop_type ILIKE '%robotic%' AND ws2.workshop_type ILIKE '%program%'
  • „Ce trainer a primit cei mai mulți copii noi luna trecută?":
    SELECT p.first_name || ' ' || p.last_name AS trainer, COUNT(DISTINCT we.child_id) AS copii_noi FROM workshop_enrollments we JOIN workshop_series ws ON we.series_id=ws.id JOIN profiles p ON ws.trainer_id=p.id JOIN children c ON we.child_id=c.id WHERE c.created_at >= date_trunc('month', now()) - interval '1 month' AND c.created_at < date_trunc('month', now()) AND we.is_active GROUP BY p.id, p.first_name, p.last_name ORDER BY copii_noi DESC LIMIT 5
  • „Câte notificări de plată neconfirmată au fost trimise săptămâna trecută?":
    SELECT COUNT(*) FROM notifications WHERE type = 'payment_due' AND created_at >= date_trunc('week', now()) - interval '1 week' AND created_at < date_trunc('week', now())

Cum raportezi rezultatele din run_read_query:
  • Extrage numere/nume din \`rows\` și transformă-le în răspuns natural românesc.
  • Menționează contextul (perioada, filtrul) dacă e relevant.
  • Dacă răspunsul are câmpul \`nota\` cu „Rezultatul a fost tăiat la 200 rânduri", spune-i utilizatorului că sunt cel puțin 200 rezultate și că trebuie să rafineze întrebarea pentru un subset specific.
  • Dacă răspunsul are \`eroare\`, spune utilizatorului că interogarea a eșuat, transcrie mesajul de eroare pe scurt și propune reformulare.

Rolul tău: nu doar să returnezi cifre brute, ci să acționezi ca analist. Când o întrebare permite o privire de ansamblu, sintetizează datele în concluzii practice.

Reguli stricte:
- Răspunde mereu în limba română, clar și concis.
- Folosește EXCLUSIV datele reale din aplicație, prin funcțiile (tools) puse la dispoziție. Nu inventa statistici, procente, sume sau nume.
- Dacă o informație nu poate fi verificată din funcțiile disponibile, spune exact: "Nu pot verifica această informație din datele aplicației."
- Nu menționa niciodată UUID-uri, ID-uri interne, nume de tabele SQL, scheme, erori brute sau detalii tehnice.
- Vorbește despre copii pe nume, despre ateliere pe titlu/tip, despre traineri pe nume.
- Sumarizează când e potrivit (ex: "5 copii activi", "3 plăți restante"). Nu lista toate înregistrările dacă nu e necesar.
- Refuză politicos cererile care nu țin de operarea centrului.

Postură analitică:
- Pentru întrebări de tip "cei mai activi", "cea mai bună/proastă prezență", "în risc", "probleme financiare", "cine necesită atenție" — folosește tool-urile analitice dedicate (get_top_children_attendance, get_workshop_attendance_analysis, get_financial_summary, get_risk_children, get_parent_account_status).
- Când răspunzi unei întrebări analitice sau de sumar, structurează răspunsul astfel:
  1. O concluzie scurtă în prima propoziție (ex: "Avem 4 copii în risc și 2 plăți restante.").
  2. Maxim 3-5 detalii ordonate după importanță (cele mai grave sau mai importante întâi).
  3. Recomandări concrete când datele le justifică (ex: "Recomand contactarea părinților lui Andrei — 60% absențe în ultimele 30 de zile" sau "Sugerez prioritizarea recuperării celor 3 plăți restante înainte de luna viitoare.").
- Pentru tendințe (ex: "creștere de absențe", "scădere de prezență"), bazează-te DOAR pe cifre returnate de tool-uri. Nu compara cu valori inventate.
- Pentru întrebări generale despre centru (program, locație, ateliere oferite), folosește tool-ul get_center_info.

Niciodată să nu fabrici un procent, o sumă sau un nume. Dacă datele nu există, spune că nu pot fi verificate.

Memorie de conversație:
- Folosește istoricul conversației pentru a rezolva întrebări de urmărire de tipul "la ce ateliere vine?", "dar el?", "explică punctul 2", "același copil", "ea". Identifică subiectul (copil, trainer, atelier) din ultimul răspuns relevant.
- Când contextul este ambiguu (ex: nu e clar la cine se referă "el"), pune o singură întrebare scurtă de clarificare în loc să presupui.
- Nu repeta tool-uri inutil. Dacă ai datele necesare deja în conversație, răspunde direct.

Participare gratuită vs plătitor:
- Fiecare copil are un tip de participare: "plătitor" (regulat, plată pe cicluri de 4 ședințe) sau "gratuit" (participare gratuită — prieten de familie, bursier, caz special).
- Copiii cu participare gratuită apar normal în întrebări despre prezență, ateliere, progres și activitate.
- Copiii cu participare gratuită NU apar în plăți restante, plăți neconfirmate, statistici financiare, alerte de plată, sumare financiare sau topuri de risc financiar.
- Când relevant pentru context (ex: la întrebări despre profilul copilului, status financiar individual, sau topuri financiare), menționează clar "participare gratuită".

Terminologie OBLIGATORIE (nu confunda niciodată aceste două concepte):
- "copii neplătitori", "copii gratuiți", "copii scutiți de plată", "participare gratuită", "cine nu plătește", "cine e gratuit", "scutiți" → înseamnă children.payment_type = 'free'. Folosește EXCLUSIV get_free_participants (sau get_payment_type_summary pentru count). NU folosi get_payments_due / get_financial_summary / get_risk_children — acelea răspund despre plăți restante, nu despre participare gratuită.
- "plăți restante", "restanțe", "neachitate", "plăți neconfirmate", "cine are restanțe", "cine nu a achitat", "datori" → înseamnă cicluri de plată (payment_cycles) cu status 'due' sau 'overdue', exclusiv pentru copii cu payment_type = 'paid'. Folosește get_payments_due sau get_financial_summary.
- Dacă utilizatorul scrie ambiguu (ex: "cine nu plătește"), pune o întrebare scurtă de clarificare: "Te referi la copii cu participare gratuită (scutiți), sau la copii cu plăți restante?"

Exemple de mapare promptă → tool:
- "Care sunt copiii neplătitori?" → get_free_participants
- "Câți copii gratuiți avem?" → get_payment_type_summary
- "Situația copiilor plătitori și neplătitori" → get_payment_type_summary
- "Cine are plăți restante?" → get_payments_due
- "Care sunt restanțele la plată?" → get_payments_due
- "Sumar financiar" → get_financial_summary
- "Cine este cel mai mare/mic copil?" → get_children_age_extremes
- "Copiii cu numele Boca" → get_children_by_last_name
- "Copii cu date lipsă" → get_children_missing_profile_data
- "Ce copii lucrează cu [nume trainer]?" → get_children_by_trainer
- "Care trainer are cei mai mulți copii?" → get_trainer_children_summary
- "Care trainer are copii cu plăți restante?" → get_trainers_with_payment_risk
- "Sumar progres", "cine are cele mai multe observații" → get_progress_summary
- "Ultimele observații de progres" → get_recent_progress_notes
- "Copii cu progres needs_review" → get_children_by_progress_status (status="needs_review")
- "Progresul lui [nume copil]" → get_child_progress_details
- "Sumar materiale", "cine a încărcat materiale" → get_materials_summary
- "Materiale pentru robotică" → get_materials_by_workshop_type
- "Materiale încărcate în ultimele 30 de zile" → get_recent_materials
- "Ce ateliere nu au materiale" → get_workshops_without_materials
- "Suma totală încasată" / "suma restantă" → NU RĂSPUNDE cu cifre monetare. Aplicația nu stochează sume per ciclu. Spune direct utilizatorului: "Aplicația nu stochează valori monetare per ciclu de plată. Pot spune doar câte cicluri sunt încasate / restante." apoi folosește get_financial_summary pentru NUMĂR de cicluri.
- "Plăți confirmate în ultimele 30 de zile" → get_recent_confirmed_payments
- "Cine e aproape de următorul ciclu de plată" → get_children_near_payment_cycle

Plăți pe METODĂ — SINGURUL tool disponibil: \`get_payments_by_method\`. Îl folosești pentru ORICE întrebare despre plăți per metodă, indiferent de formulare (nume, distribuție, count). Nu există alt tool concurent. Câmpurile din răspunsul lui acoperă atât detalii individuale (pe_metoda.<METODĂ>.plati[] cu nume + confirmatori) cât și agregate (pe_metoda.<METODĂ>.total, total_plati). Pentru „distribuția pe metode luna aceasta" apelezi tot \`get_payments_by_method\` cu \`methods=["pos","op","unknown"]\` + fereastra dorită, apoi citești numerele din \`pe_metoda.*.total\`.

REGULĂ ABSOLUTĂ — SUME MONETARE (FĂRĂ EXCEPȚIE):
Aplicația NU stochează sume monetare (RON, lei, EUR) per ciclu de plată. Coloana payment_cycles.amount este NULL în toate rândurile. NU MENȚIONA sume sau prețuri niciodată în răspunsuri despre plăți POS/OP:
- INTERZIS: "300 RON", "350 lei", "Total: 700 RON încasat", "suma încasată", "valoare per ciclu"
- INTERZIS chiar și dacă utilizatorul întreabă direct despre sume — răspunzi: "Aplicația nu stochează valori monetare per ciclu. Pot spune doar cine a plătit, când și prin ce metodă."
- Pentru orice întrebare de tip „cât s-a încasat / cât e restant / suma totală / cât a plătit X" → răspunzi cu propoziția de mai sus și ofertă alternativa (număr de cicluri via get_financial_summary, listă de plăți via get_payments_by_method).
- NU FABRICA valori inventate ca „300 RON", chiar dacă răspunsul pare mai complet cu ele. Dacă tool-ul nu returnează un câmp \`suma\`, nu adăuga tu unul.

Ce POȚI menționa despre plăți POS/OP: copil, părinte, metodă (POS/OP), data confirmării (paid_at), cine a confirmat, statusul ("Plată confirmată" sau "Achitat în avans"), perioada ciclului, număr de ședințe. Atât.

DEZAMBIGUARE lună calendaristică (rezolvă „luna X" ÎNAINTE să chemi tool-ul):
- „luna ianuarie" / „ianuarie" → month=1
- „luna februarie" / „februarie" → month=2
- „luna martie" / „martie" → month=3
- „luna aprilie" / „aprilie" → month=4
- „luna mai" / „mai" (când e nume de lună, NU adverb) → month=5. Contextul: dacă „mai" apare după „luna", „în", „din" → este luna 5. Nu-l interpreta ca „mai mult".
- „luna iunie" / „iunie" → month=6
- „luna iulie" / „iulie" → month=7
- „luna august" / „august" → month=8
- „luna septembrie" / „septembrie" → month=9
- „luna octombrie" / „octombrie" → month=10
- „luna noiembrie" / „noiembrie" → month=11
- „luna decembrie" / „decembrie" → month=12
- „luna aceasta" / „luna curentă" → month = luna curentă (folosește data curentă din sistem)
- „luna trecută" → month = luna anterioară (dacă luna curentă e 1, atunci month=12 și year-=1)
Dacă utilizatorul nu specifică anul, folosește anul curent.


Parametrii cheie:
- methods: ARRAY de metode ("pos", "op", "unknown"). Include multiple metode când utilizatorul întreabă despre mai multe. Pentru "toate plățile POS și OP" trimite methods=["pos", "op"].
- year + month: pentru fereastră de o lună calendaristică. Ex: "în luna iunie" → year=2026, month=6 (dacă anul e omis, se folosește anul curent).
- days: fallback când nu se specifică o lună. Implicit 30.
- limit_per_method: implicit 100, taie fiecare grup separat.

Routing rules (fii strict):
- "cine a plătit cu POS", "cine a plătit cu cardul", "plăți POS", "plăți card", "plăți cu cardul" → methods=["pos"]
- "cine a plătit cu OP", "cine a plătit prin OP", "plăți prin OP", "plăți OP" → methods=["op"]
- "cine a plătit prin transfer", "prin transfer bancar", "bank transfer", "ordin de plată" → methods=["op"]
- "arată-mi toate plățile POS și OP din iunie", "grupează plățile după metodă", "POS și OP" → methods=["pos", "op"] + year+month dacă se specifică luna
- "toate plățile confirmate din luna X" (fără a specifica metoda) → methods=["pos", "op", "unknown"] + year+month
- "Pentru fiecare plată POS sau OP, spune-mi copilul, data și cine a confirmat-o" → methods=["pos", "op"] — răspunde cu detalii per plată, NU cu un simplu total. NU menționa sume (nu sunt stocate).
- "Câte plăți POS sunt confirmate luna aceasta?" → methods=["pos"] cu year+month = luna curentă (folosește "total_plati" din răspuns pentru numărare)
- "Plăți confirmate fără metodă înregistrată" → methods=["unknown"]
- "Distribuția plăților pe metode" → tot get_payments_by_method (methods=["pos","op","unknown"]), apoi citește pe_metoda.*.total din răspuns. NU există alt tool separat pentru distribuție.

Terminologie metode de plată — folosește EXACT aceste alias-uri și nu inventa altele:
- POS = plată cu cardul (la POS-ul centrului). Alias-uri acceptate: "POS", "card", "cu cardul", "prin POS".
- OP = ordin de plată = transfer bancar. Alias-uri acceptate: "OP", "transfer", "transfer bancar", "bank transfer", "ordin de plată", "prin transfer".
- Dacă utilizatorul întreabă despre o metodă care NU e POS sau OP (ex: "cash", "numerar", "cec", "PayPal"), NU inventa un răspuns. Apelează get_payments_by_method cu methods=["pos","op","unknown"] și explică politicos, pe baza rezultatelor, că doar POS și OP sunt înregistrate în sistem.

Cum raportezi rezultatele din get_payments_by_method:
- Menționează fereastra (câmpul "fereastra" din răspuns).
- GRUPEAZĂ plățile pe metodă folosind câmpul "pe_metoda" din răspuns. Pentru fiecare grup afișează:
    POS:
    1. <copil> — <confirmed_at (format DD.MM.YYYY)> — confirmată de <confirmat_de>.
    2. …
    OP:
    1. …
- REGULĂ ABSOLUTĂ (nu-i sări niciodată): dacă tool-ul returnează plăți în "pe_metoda.<METODĂ>.plati", TREBUIE să listezi fiecare plată individual cu câmpul "copil" din acel row. NU răspunde cu doar totalul. NU spune că "numele nu sunt disponibile" — câmpul "copil" există pe FIECARE row returnat de tool.
- Fiecare plată din "pe_metoda.<METODĂ>.plati" TREBUIE afișată cu: numele copilului ("copil"), data confirmării ("confirmed_at", format DD.MM.YYYY), și cine a confirmat ("confirmat_de"). Dacă "confirmed_at" e null, folosește "created_at" în loc și scrie "înregistrat la" în loc de "confirmat la". NU MENȚIONA SUME MONETARE — nu sunt disponibile în răspuns și e INTERZIS să inventezi.
- Câmpuri opționale de menționat când sunt cerute explicit sau când completează contextul: numele părintelui ("parinte"), status ("Plată confirmată" pentru "paid" sau "Achitat în avans" pentru "paid_advance"), perioada ciclului ("perioada"), ședințe ("sedinte").
- Dacă un câmp opțional e null (ex: părinte lipsă), scrie "nu este înregistrat", NU spune că datele nu pot fi obținute.
- Fallback pentru copii nerezolvați: dacă "copil" începe cu "child_id: … (nume nerezolvat)", listează totuși plata cu acel string ca identificator. Nu o omite.
- La final, poți adăuga un sumar cu NUMĂRUL de plăți: "Total: 4 plăți confirmate prin POS și OP în perioada Y" (folosește câmpul "total_plati"). NU adăuga sume monetare.
- Dacă un grup are 0 plăți, spune-o explicit: "POS: nicio plată în această perioadă" — NU omite grupul.
- Dacă răspunsul are câmpul "nota" nenull, transcrie-l în răspuns și NU inventa cifre.
- Ignoră blocul "debug" din răspuns — e pentru diagnostic, nu pentru utilizator.
- "Cele mai bune/slabe ateliere" → get_attendance_by_workshop_rankings (sample-size ≥ 3 implicit)
- "Probleme cu denumirile atelierelor" → get_workshop_name_quality_issues

Reguli de calitate a răspunsurilor:
- Atunci când un metric NU poate fi calculat pentru că lipsesc date (ex: payment_cycles.amount NULL, child_progress dezactivat, lesson_materials dezactivat), spune exact ce lipsește. Folosește câmpul "nota" din răspunsul tool-ului și transcrie-l în răspuns; NU inventa cifre.
- NU clasifica niciodată un atelier ca "cel mai bun" sau "cel mai prost" dacă are 0 ședințe marcate sau mai puțin de 3 prezențe înregistrate. Tool-urile dedicate (get_attendance_by_workshop_rankings, get_workshop_attendance_analysis) deja exclud automat acest set; respectă rezultatul lor.
- "neplătitor" în context de PARTICIPARE = get_free_participants. "neplătitor" în context de PLATĂ RESTANTĂ = get_payments_due. Dacă propoziția este ambiguă, cere o clarificare scurtă.
- Pentru "plăți restante", "neachitate", "neconfirmate" → mereu get_payments_due / get_financial_summary, NICIODATĂ get_free_participants.

Formatare Markdown (LISTE NUMEROTATE):
- Folosește SIEMPRE formatul "N. text" pe câte o linie singură, cu spațiu după punct, fără cifre rupte între linii.
  Corect:
    1. Primul punct
    2. Al doilea punct
    10. Al zecelea punct
  Incorect (nu face niciodată asta):
    1
    0. (cifra 10 nu trebuie spartă pe două linii)
- Niciodată nu pune un newline între o cifră și punctul de listă.
- Pentru subliste folosește indentare cu 3 spații înainte de "1.".`;

// ── Tools ───────────────────────────────────────────────────────────────────

interface ToolDef {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

const TOOLS: ToolDef[] = [
  {
    name: "get_dashboard_summary",
    description:
      "Statistici generale agregate: copii activi, ateliere active, prezențe săptămâna curentă, plăți restante.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_children_summary",
    description:
      "Returnează totalul copiilor activi/inactivi și o listă scurtă cu primele nume (max 50).",
    parameters: {
      type: "object",
      properties: {
        only_active: {
          type: "boolean",
          description: "Dacă true, listează doar copiii activi. Implicit true.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "search_child_by_name",
    description:
      "Caută copii după nume sau prenume (potrivire parțială, fără diacritice). Returnează maxim 10 rezultate cu informațiile de bază.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "Text de căutare (nume / prenume)." },
      },
      required: ["query"],
      additionalProperties: false,
    },
  },
  {
    name: "get_child_details",
    description:
      "Detalii sumarizate pentru un copil: ateliere active, ultimul status de prezență, ultimul ciclu de plată.",
    parameters: {
      type: "object",
      properties: {
        child_name: { type: "string", description: "Numele complet al copilului." },
      },
      required: ["child_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_workshops",
    description:
      "Listează atelierele într-un interval. Acceptă filtru: today, this_week, next_week sau interval de date explicit.",
    parameters: {
      type: "object",
      properties: {
        scope: {
          type: "string",
          enum: ["today", "this_week", "next_week", "custom"],
          description: "Intervalul dorit.",
        },
        from: { type: "string", description: "Doar pentru scope=custom, format YYYY-MM-DD." },
        to: { type: "string", description: "Doar pentru scope=custom, format YYYY-MM-DD." },
      },
      required: ["scope"],
      additionalProperties: false,
    },
  },
  {
    name: "get_attendance_summary",
    description:
      "Rata generală de prezență pentru o fereastră de timp. Implicit ultimele 30 de zile.",
    parameters: {
      type: "object",
      properties: {
        days: {
          type: "integer",
          minimum: 1,
          maximum: 365,
          description: "Câte zile în urmă să cuprindă fereastra. Implicit 30.",
        },
        child_name: {
          type: "string",
          description: "Dacă e furnizat, calculează rata doar pentru acel copil.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_payments_due",
    description:
      "Ciclurile de plată cu status due sau overdue. Returnează numele copiilor afectați și totalurile.",
    parameters: {
      type: "object",
      properties: {
        only_overdue: {
          type: "boolean",
          description: "Dacă true, doar restante. Altfel due+overdue.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_trainers_summary",
    description:
      "Listă traineri cu numărul de ateliere active asignate fiecăruia.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_demo_workshops_summary",
    description:
      "Sumarul atelierelor demo: viitoare, finalizate, convertite. Acceptă filtru pe status.",
    parameters: {
      type: "object",
      properties: {
        scope: {
          type: "string",
          enum: ["upcoming", "past", "all"],
          description: "Implicit upcoming.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_center_info",
    description:
      "Informații statice despre centru: adresă, program, tipuri de ateliere oferite. Date editoriale, nu din baza de date.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_top_children_attendance",
    description:
      "Topul copiilor după rata de prezență într-o fereastră de zile. Răspunde la întrebări precum 'cei mai activi copii', 'top după prezență', 'cine are prezență 100%'.",
    parameters: {
      type: "object",
      properties: {
        days: {
          type: "integer",
          minimum: 7,
          maximum: 365,
          description: "Mărimea ferestrei în zile. Implicit 90.",
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 50,
          description: "Câți copii să fie returnați în top. Implicit 10.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_workshop_attendance_analysis",
    description:
      "Analiză pe atelier: prezențe, absențe, rată de prezență. Răspunde la întrebări precum 'care atelier are cea mai bună prezență', 'care atelier are cele mai multe absențe', 'ce atelier performează cel mai bine'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_financial_summary",
    description:
      "Sumar financiar: cicluri neîncasate (due), restante (overdue), achitate luna aceasta și copiii cu cele mai multe plăți restante. Nu returnează sume monetare exacte (prețul/sesiune nu este stocat în aplicație).",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_risk_children",
    description:
      "Identifică copii care necesită atenție: prezență sub 50%, mai mult de 3 absențe în ultimele 60 de zile, sau plăți restante. Returnează lista ordonată după gravitate, cu motivele specifice.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_parent_account_status",
    description:
      "Starea conturilor de părinți: câți părinți și-au activat contul, câte invitații sunt încă neutilizate, copii fără părinte asociat. Utile pentru a urmări procesul de onboarding.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Overview / dashboard ──────────────────────────────────────────────────
  {
    name: "get_center_overview",
    description:
      "Sumar consolidat al centrului: copii activi, ateliere active, ateliere astăzi, plăți restante, copii în risc. Folosește pentru întrebări generale ('cum stăm', 'situația actuală').",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_today_summary",
    description:
      "Ce se întâmplă astăzi: ateliere programate, prezențe marcate azi, ateliere demo. Folosește pentru întrebări de tip 'ce avem azi'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_week_summary",
    description:
      "Sumar pe săptămâna curentă: ateliere, prezențe/absențe agregate, rata de prezență, ateliere demo. Folosește pentru 'cum a fost săptămâna' sau 'ce mai e săptămâna asta'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_month_summary",
    description:
      "Sumar pe luna curentă: ateliere, prezențe, rata de prezență, plăți încasate, copii noi.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_important_alerts",
    description:
      "Listă scurtă de alerte operaționale: plăți restante, ateliere viitoare fără trainer, serii fără copii, ateliere demo viitoare. Folosește pentru 'ce trebuie să știu acum'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_data_quality_issues",
    description:
      "Audit de igienă a datelor: copii fără data nașterii / telefon părinte, ateliere fără trainer, copii activi fără atelier, posibile duplicate, cicluri de plată suspecte. Folosește pentru 'ce date lipsă avem' sau 'ce inconsistențe sunt'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Children variants ─────────────────────────────────────────────────────
  {
    name: "get_child_profile",
    description:
      "Sinonim pentru get_child_details. Profil sumarizat al unui copil: ateliere active, ultima prezență, ultimul ciclu de plată.",
    parameters: {
      type: "object",
      properties: {
        child_name: { type: "string", description: "Numele copilului." },
      },
      required: ["child_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_child_active_workshops",
    description:
      "Atelierele active la care este înscris un copil.",
    parameters: {
      type: "object",
      properties: {
        child_name: { type: "string", description: "Numele copilului." },
      },
      required: ["child_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_child_recent_activity",
    description:
      "Ultimele înregistrări de prezență pentru un copil (data, atelier, status, observație).",
    parameters: {
      type: "object",
      properties: {
        child_name: { type: "string", description: "Numele copilului." },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 30,
          description: "Câte intrări recente. Implicit 10.",
        },
      },
      required: ["child_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_children_without_active_workshop",
    description:
      "Copii activi care nu sunt înscriși la niciun atelier. Util pentru re-engajare.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_children_with_multiple_workshops",
    description:
      "Copii înscriși la mai mult de un atelier activ, ordonați după numărul de ateliere.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_children_by_workshop_type",
    description:
      "Copiii înscriși la o categorie de ateliere (Robotică, Lectură, Modelare 3D, etc.).",
    parameters: {
      type: "object",
      properties: {
        workshop_type: {
          type: "string",
          description: "Categoria (ex: 'robotic', 'lectur', 'modelare').",
        },
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      required: ["workshop_type"],
      additionalProperties: false,
    },
  },
  {
    name: "get_new_children_this_month",
    description:
      "Copii noi înscriși luna curentă (după created_at).",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_inactive_children",
    description:
      "Copii marcați ca inactivi (is_active=false).",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_children_birthdays_upcoming",
    description:
      "Aniversări ale copiilor activi în zilele următoare (folosește pentru 'cine își aniversează ziua').",
    parameters: {
      type: "object",
      properties: {
        days: {
          type: "integer",
          minimum: 1,
          maximum: 90,
          description: "Fereastra în zile. Implicit 30.",
        },
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },

  // ── Attendance ────────────────────────────────────────────────────────────
  {
    name: "get_attendance_by_date",
    description:
      "Sumar de prezență pentru o dată exactă (YYYY-MM-DD).",
    parameters: {
      type: "object",
      properties: {
        date: { type: "string", description: "Data în format YYYY-MM-DD." },
      },
      required: ["date"],
      additionalProperties: false,
    },
  },
  {
    name: "get_attendance_by_workshop",
    description:
      "Sumar de prezență pentru un atelier (potrivire după titlu), într-o fereastră de zile.",
    parameters: {
      type: "object",
      properties: {
        workshop_title: { type: "string", description: "Titlul atelierului." },
        days: { type: "integer", minimum: 7, maximum: 365 },
      },
      required: ["workshop_title"],
      additionalProperties: false,
    },
  },
  {
    name: "get_attendance_by_trainer",
    description:
      "Sumar de prezență pe sesiunile asignate unui trainer, într-o fereastră de zile.",
    parameters: {
      type: "object",
      properties: {
        trainer_name: { type: "string", description: "Numele trainerului." },
        days: { type: "integer", minimum: 7, maximum: 365 },
      },
      required: ["trainer_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_children_with_consecutive_absences",
    description:
      "Copii cu un șir de absențe consecutive (cele mai recente). Util pentru detectarea riscului de abandon.",
    parameters: {
      type: "object",
      properties: {
        min_run: {
          type: "integer",
          minimum: 2,
          maximum: 10,
          description: "Pragul minim de absențe consecutive. Implicit 2.",
        },
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_motivated_absences",
    description:
      "Absențele marcate ca motivate într-o fereastră de zile, cu top copii și ultimele observații.",
    parameters: {
      type: "object",
      properties: {
        days: { type: "integer", minimum: 7, maximum: 365 },
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "compare_attendance_periods",
    description:
      "Compară rata de prezență din ultimele N zile cu cea din N zile anterioare. Returnează trend (creștere/scădere/stabil).",
    parameters: {
      type: "object",
      properties: {
        window_days: {
          type: "integer",
          minimum: 7,
          maximum: 180,
          description: "Lungimea ferestrei. Implicit 30.",
        },
      },
      additionalProperties: false,
    },
  },

  // ── Workshops ─────────────────────────────────────────────────────────────
  {
    name: "get_workshops_by_type",
    description:
      "Serii active de o anumită categorie (Robotică, Lectură, Modelare 3D, etc.).",
    parameters: {
      type: "object",
      properties: {
        workshop_type: { type: "string", description: "Categoria țintă." },
      },
      required: ["workshop_type"],
      additionalProperties: false,
    },
  },
  {
    name: "get_workshops_by_trainer",
    description:
      "Seriile active asignate unui anumit trainer.",
    parameters: {
      type: "object",
      properties: {
        trainer_name: { type: "string", description: "Numele trainerului." },
      },
      required: ["trainer_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_active_workshop_series",
    description:
      "Toate seriile active de ateliere, cu trainerul și orarul.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 100 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_workshop_children",
    description:
      "Copiii înscriși la un atelier (potrivire după titlu).",
    parameters: {
      type: "object",
      properties: {
        workshop_title: { type: "string", description: "Titlul atelierului." },
      },
      required: ["workshop_title"],
      additionalProperties: false,
    },
  },
  {
    name: "get_most_popular_workshops",
    description:
      "Top serii după numărul de copii înscriși activ. Setează 'least' pe true pentru cele mai puțin populare.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 30 },
        least: { type: "boolean", description: "Dacă true, ordonează crescător." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_workshops_without_children",
    description:
      "Serii active care nu au niciun copil activ înscris.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_workshops_without_trainer",
    description:
      "Sesiuni viitoare și serii active fără trainer asignat.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_workshop_capacity_summary",
    description:
      "Procent de ocupare aproximativ pentru fiecare serie activă, raportat la capacitatea-țintă de 10 copii/grupă.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Trainers ──────────────────────────────────────────────────────────────
  {
    name: "get_trainer_profile",
    description:
      "Profilul unui trainer: serii active și volum sesiuni în ultimele 30 de zile.",
    parameters: {
      type: "object",
      properties: {
        trainer_name: { type: "string", description: "Numele trainerului." },
      },
      required: ["trainer_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_trainer_workload",
    description:
      "Volumul de sesiuni programate per trainer într-o fereastră de zile, ordonat descrescător.",
    parameters: {
      type: "object",
      properties: {
        days: { type: "integer", minimum: 7, maximum: 180 },
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_trainer_week_schedule",
    description:
      "Sesiunile săptămânii curente pentru un anumit trainer, ordonate cronologic.",
    parameters: {
      type: "object",
      properties: {
        trainer_name: { type: "string", description: "Numele trainerului." },
      },
      required: ["trainer_name"],
      additionalProperties: false,
    },
  },

  // ── Parents ───────────────────────────────────────────────────────────────
  {
    name: "search_parent_by_name_or_email",
    description:
      "Caută părinți după nume sau parțial după email (din tokenurile de invitație). Adresele de email nu sunt expuse direct.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "Text de căutare." },
        limit: { type: "integer", minimum: 1, maximum: 30 },
      },
      required: ["query"],
      additionalProperties: false,
    },
  },
  {
    name: "get_parent_children",
    description:
      "Copiii asociați unui părinte (după nume).",
    parameters: {
      type: "object",
      properties: {
        parent_name: { type: "string", description: "Numele părintelui." },
      },
      required: ["parent_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_pending_parent_setups",
    description:
      "Invitațiile de părinte active (token încă valabil, neutilizat) cu email, data trimiterii, data expirării, numărul de încercări.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_expired_parent_setups",
    description:
      "Invitații expirate al căror destinatar NU și-a activat ulterior contul. Necesită retrimiterea invitației.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },

  // ── Payments ──────────────────────────────────────────────────────────────
  //
  // Note: get_payment_method_summary was removed on 2026-07-09. It was a
  // pure aggregate (POS/OP counts, no names) that competed with
  // get_payments_by_method for routing and caused GPT-4o-mini to
  // inconsistently pick the aggregate one — even when the user asked
  // "cine a plătit cu POS" (which needs names). Since get_payments_by_method
  // already returns per-method totals in `pe_metoda.<METHOD>.total`,
  // no functionality was lost: distribution questions read the totals
  // from that response instead. Deleting the tool eliminates the
  // routing ambiguity entirely.
  {
    name: "get_payments_by_method",
    description:
      "Listează plățile confirmate filtrate după una sau mai multe metode (POS, " +
      "OP/transfer bancar, unknown). Rezultatele sunt grupate pe metodă. " +
      "Pentru fiecare plată returnează: id ciclu, nume copil, numele părintelui, " +
      "sumă, monedă, data plății (paid_at), created_at, status, metodă, " +
      "confirmed_by (numele utilizatorului care a confirmat plata), perioada " +
      "ciclului, ședințe. Folosește pentru: 'cine a plătit cu POS', 'cine a " +
      "plătit prin OP', 'arată-mi toate plățile POS și OP din iunie', 'grupează " +
      "plățile după metodă'. Alias-uri recunoscute automat: 'card' → pos; " +
      "'transfer', 'transfer bancar', 'bank transfer', 'ordin de plată' → op.",
    parameters: {
      type: "object",
      properties: {
        methods: {
          type: "array",
          items: {
            type: "string",
            enum: ["pos", "op", "unknown"],
          },
          minItems: 1,
          uniqueItems: true,
          description:
            "Metodele de plată de returnat. Poate conține una sau mai multe din " +
            "'pos' (card/POS), 'op' (transfer bancar / OP / ordin de plată), " +
            "'unknown' (plăți confirmate fără metodă înregistrată). Pentru " +
            "'arată-mi POS și OP' trimite [\"pos\", \"op\"].",
        },
        year: {
          type: "integer",
          minimum: 2020,
          maximum: 2100,
          description:
            "Anul ferestrei de căutare. Combinat cu [month] restrânge la o " +
            "lună calendaristică (paid_at ∈ [1-a, ultima_zi]). Dacă lipsește " +
            "și există [month], se folosește anul curent.",
        },
        month: {
          type: "integer",
          minimum: 1,
          maximum: 12,
          description:
            "Luna (1-12). Combinată cu [year] filtrează plățile cu paid_at " +
            "în acea lună. Ignorat dacă lipsește.",
        },
        days: {
          type: "integer",
          minimum: 1,
          maximum: 365,
          description:
            "Fereastra de zile în urmă când NU se folosește year/month " +
            "(implicit 30).",
        },
        limit_per_method: {
          type: "integer",
          minimum: 1,
          maximum: 200,
          description:
            "Maxim plăți returnate per metodă (implicit 100). Grupele fiecărei " +
            "metode sunt tăiate separat la această limită.",
        },
      },
      required: ["methods"],
      additionalProperties: false,
    },
  },
  {
    name: "get_advance_paid_cycles",
    description:
      "Cicluri de plată achitate în avans, cu copilul, data plății, metoda, sesiunile incluse.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_cancelled_payment_cycles",
    description:
      "Cicluri de plată anulate (status=cancelled).",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_payment_cycles_by_child",
    description:
      "Istoria ciclurilor de plată pentru un copil, ordonată cronologic descrescător.",
    parameters: {
      type: "object",
      properties: {
        child_name: { type: "string", description: "Numele copilului." },
        limit: { type: "integer", minimum: 1, maximum: 30 },
      },
      required: ["child_name"],
      additionalProperties: false,
    },
  },

  // ── Notifications ─────────────────────────────────────────────────────────
  {
    name: "get_notifications_summary",
    description:
      "Sumar notificări: total în ultimele 30 de zile, necitite total, distribuție pe tip.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_recent_notifications",
    description:
      "Cele mai recente notificări cu titlu, tip, citită/necitită și data.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 30 },
      },
      additionalProperties: false,
    },
  },

  // ── Insight composites ────────────────────────────────────────────────────
  {
    name: "get_weekly_action_plan",
    description:
      "Plan de acțiune săptămânal: sumar săptămână + alerte + acțiuni recomandate cu top 3 priorități înalte.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_growth_opportunities",
    description:
      "Oportunități de creștere identificate din date: serii aproape pline, serii sub-utilizate, demo de convertit, copii fără atelier, copii fără părinte.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_admin_priority_list",
    description:
      "Lista prioritizată pentru administrator: priorități imediate + acțiuni săptămână + oportunități + igiena datelor.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Participation type (paid vs free) ─────────────────────────────────────
  //
  // These tools are the canonical answer for any prompt that names
  // "neplătitori", "gratuiți", "scutiți de plată", "participare gratuită",
  // or "copii plătitori / neplătitori". They surface children.payment_type
  // directly — completely separate from the payment-cycle world (due /
  // overdue). Mixing the two is the classic confusion the assistant must
  // avoid.
  {
    name: "get_free_participants",
    description:
      "Listează copiii cu participare gratuită (children.payment_type = 'free'): " +
      "prieteni de familie, bursieri, cazuri speciale. " +
      "Folosește acest tool pentru întrebări de tip: 'copii neplătitori', " +
      "'copii gratuiți', 'participare gratuită', 'scutiți de plată', " +
      "'cine nu plătește'. NU este același lucru cu 'plăți restante' sau " +
      "'plăți neconfirmate' — acelea sunt cicluri de plată cu status " +
      "due/overdue (folosește get_payments_due pentru ele).",
    parameters: {
      type: "object",
      properties: {
        only_active: {
          type: "boolean",
          description:
            "Dacă true (implicit), listează doar copiii activi. Dacă false, " +
            "include și copiii inactivi.",
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 100,
          description: "Maxim copii returnați în listă. Implicit 30.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_payment_type_summary",
    description:
      "Sumarul copiilor după tipul de participare (payment_type): " +
      "câți plătitori și câți gratuiți, total și activi. " +
      "Folosește pentru 'situația copiilor plătitori și neplătitori', " +
      "'câți copii gratuiți avem', 'distribuția pe tip de participare'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Children profile intelligence ─────────────────────────────────────────
  {
    name: "get_children_age_extremes",
    description:
      "Cel mai mare și cel mai mic copil activ din centru (cu vârstă și data nașterii). " +
      "Folosește pentru 'cine este cel mai mare/mic copil', 'top vârste'.",
    parameters: {
      type: "object",
      properties: {
        only_active: {
          type: "boolean",
          description: "Implicit true; setează false pentru a include și inactivi.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_children_by_last_name",
    description:
      "Caută copii după nume de familie (potrivire parțială, fără diacritice). " +
      "Returnează status activ, atelierul asignat și contactul părintelui. " +
      "Folosește pentru 'copiii cu numele Boca', 'familia Popescu'.",
    parameters: {
      type: "object",
      properties: {
        last_name: { type: "string", description: "Nume de familie." },
      },
      required: ["last_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_children_missing_profile_data",
    description:
      "Copii activi cu date importante lipsă: birth_date, parent_phone, parent_name, " +
      "atelier asignat. Folosește pentru 'copii cu date incomplete', 'igiena datelor copii'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Trainer ↔ children relationships ──────────────────────────────────────
  {
    name: "get_children_by_trainer",
    description:
      "Listează copiii unui trainer, grupați pe atelier. Deduplică copilul " +
      "când apare în mai multe ședințe ale aceleiași serii recurente. " +
      "Folosește pentru 'ce copii lucrează cu Tofan Anghel'.",
    parameters: {
      type: "object",
      properties: {
        trainer_name: { type: "string", description: "Numele complet al trainerului." },
      },
      required: ["trainer_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_trainer_children_summary",
    description:
      "Pentru fiecare trainer: numărul de ateliere active, copii unici, copii plătitori, " +
      "copii cu participare gratuită. Folosește pentru 'care trainer are cei mai mulți copii'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_trainers_with_payment_risk",
    description:
      "Traineri cu copii ce au plăți restante (due/overdue) în atelierele lor. " +
      "Exclude automat copiii cu participare gratuită. " +
      "Folosește pentru 'ce trainer are copii cu plăți restante'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Child progress ────────────────────────────────────────────────────────
  {
    name: "get_progress_summary",
    description:
      "Sumar global al observațiilor de progres: total, luna curentă, " +
      "pe status, top copii și top traineri după număr de observații. " +
      "Folosește pentru 'sumar progres', 'cine are cele mai multe observații'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_recent_progress_notes",
    description:
      "Ultimele observații de progres din centru. Folosește pentru " +
      "'ultimele observații', 'progresul recent al copiilor'.",
    parameters: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 50,
          description: "Maxim observații returnate. Implicit 10.",
        },
        days: {
          type: "integer",
          minimum: 1,
          maximum: 365,
          description: "Fereastra în zile pentru filtrare. Implicit 30.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_children_by_progress_status",
    description:
      "Copii grupați după status-ul ultimei observații de progres " +
      "(completed | in_progress | needs_review). Folosește pentru " +
      "'copii cu progres needs_review', 'cine necesită atenție'.",
    parameters: {
      type: "object",
      properties: {
        status: {
          type: "string",
          enum: ["completed", "in_progress", "needs_review"],
          description: "Status-ul progresului.",
        },
      },
      required: ["status"],
      additionalProperties: false,
    },
  },
  {
    name: "get_child_progress_details",
    description:
      "Istoricul observațiilor de progres pentru un copil specific. " +
      "Folosește pentru 'progresul lui Maria Popescu'.",
    parameters: {
      type: "object",
      properties: {
        child_name: { type: "string", description: "Numele complet al copilului." },
      },
      required: ["child_name"],
      additionalProperties: false,
    },
  },

  // ── Lesson materials ──────────────────────────────────────────────────────
  {
    name: "get_materials_summary",
    description:
      "Sumar materiale didactice: total active, pe tip de atelier, încărcate luna curentă, " +
      "uploaderi după număr de materiale. Folosește pentru 'sumar materiale', " +
      "'cine a încărcat cele mai multe materiale'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_materials_by_workshop_type",
    description:
      "Materiale didactice filtrate după tipul de atelier (robotică, programare etc.). " +
      "Folosește pentru 'ce materiale avem pentru robotică'.",
    parameters: {
      type: "object",
      properties: {
        workshop_type: {
          type: "string",
          description: "Tipul atelierului (text liber).",
        },
      },
      required: ["workshop_type"],
      additionalProperties: false,
    },
  },
  {
    name: "get_recent_materials",
    description:
      "Cele mai recente materiale active. Folosește pentru " +
      "'ce materiale au fost încărcate recent'.",
    parameters: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 50,
          description: "Maxim materiale returnate. Implicit 10.",
        },
        days: {
          type: "integer",
          minimum: 1,
          maximum: 365,
          description: "Fereastra în zile. Implicit 30.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_workshops_without_materials",
    description:
      "Tipuri de atelier active care nu au niciun material încărcat. " +
      "Folosește pentru 'ce ateliere nu au materiale'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Payment intelligence ──────────────────────────────────────────────────
  //
  // Note (2026-08-14): get_payment_amount_summary was removed. The
  // aplication does not store per-cycle amounts (every payment_cycles
  // row has amount IS NULL), and exposing a tool that talks about
  // "totals" invited the model to fabricate values. The composite
  // tools that used to include amount data (weekly action plan,
  // admin priority list) still call it via a stub that returns a
  // "sums-not-tracked" note so callers don't break.
  {
    name: "get_recent_confirmed_payments",
    description:
      "Plăți confirmate recent: numele copilului, suma (dacă există), valuta, " +
      "data plății, cine a confirmat, metoda. Folosește pentru 'plăți confirmate ultima săptămână'.",
    parameters: {
      type: "object",
      properties: {
        days: {
          type: "integer",
          minimum: 1,
          maximum: 365,
          description: "Fereastra în zile. Implicit 30.",
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 50,
          description: "Maxim plăți returnate. Implicit 20.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_children_near_payment_cycle",
    description:
      "Copii plătitori cu 3 prezențe în ciclul curent — la o singură prezență de " +
      "finalizare. Niciodată include copii cu participare gratuită. " +
      "Folosește pentru 'cine e aproape de următoarea plată'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Workshop name / attendance quality ────────────────────────────────────
  {
    name: "get_attendance_by_workshop_rankings",
    description:
      "Top atelierelor după rata de prezență, separat pentru cele mai bune și " +
      "cele mai slabe. Exclude implicit atelierele cu zero copii sau zero ședințe " +
      "(le raportează ca 'fără date suficiente'). Folosește pentru 'cele mai bune/slabe ateliere'.",
    parameters: {
      type: "object",
      properties: {
        days: {
          type: "integer",
          minimum: 7,
          maximum: 365,
          description: "Fereastră în zile. Implicit 90.",
        },
        include_zero_sample: {
          type: "boolean",
          description:
            "Implicit false. Setează true doar dacă userul cere explicit ateliere fără date.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_workshop_name_quality_issues",
    description:
      "Probleme de calitate ale denumirilor de ateliere: nume cu litere mici, " +
      "duplicate care diferă doar prin case, ateliere active fără copii, " +
      "ateliere inactive care încă apar în analize.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },

  // ── Escape hatch: arbitrary SELECT (SQL-writing model, use with care)
  {
    name: "run_read_query",
    description:
      "Rulează o interogare SQL SELECT arbitrară pe schema public. " +
      "Folosește DOAR când nicio altă unealtă nu răspunde întrebării — " +
      "interogări ad-hoc, cross-joins, agregate nespecifice. Uneltele " +
      "dedicate (get_children_summary, get_payments_by_method, etc.) sunt " +
      "MULT MAI RAPIDE și mai fiabile — preferă-le mereu când există. " +
      "\n\nCe poți face:" +
      "\n  • SELECT / WITH ... SELECT pe orice tabelă din schema public " +
      "  (children, workshop_series, scheduled_workshops, workshop_enrollments, " +
      "  attendance, payment_cycles, profiles, notifications, demo_workshops, " +
      "  team_chat_messages, child_progress, lesson_materials, etc.)" +
      "\n  • JOIN-uri, agregate, CTE-uri, funcții de fereastră" +
      "\n\nCe NU poți face (blocat structural):" +
      "\n  • INSERT / UPDATE / DELETE / DROP / ALTER / CREATE — orice DML/DDL" +
      "\n  • Nu poți referi schemele auth, storage, realtime, cron, pg_*, " +
      "  vault, information_schema" +
      "\n  • Coloanele cu parole și tokenuri (encrypted_password, token_hash, " +
      "  refresh_token, secret_key etc.) sunt filtrate automat din răspuns" +
      "\n\nLimite: maxim 200 rânduri returnate (dacă query-ul nu are propriu " +
      "LIMIT); timeout 10 secunde per interogare.",
    parameters: {
      type: "object",
      properties: {
        sql: {
          type: "string",
          description:
            "Interogarea SQL. Trebuie să înceapă cu SELECT sau WITH. " +
            "Fără ; final. Adaugă LIMIT propriu dacă vrei mai puține rezultate.",
        },
        description: {
          type: "string",
          description:
            "O propoziție scurtă care descrie ce încerci să afli. Ex: " +
            "'Numărul copiilor înscriși luna trecută pe tip de atelier.'",
        },
      },
      required: ["sql", "description"],
      additionalProperties: false,
    },
  },
];

// ── Tool implementations ────────────────────────────────────────────────────

const ROMANIAN_DAYS = [
  "Duminică", "Luni", "Marți", "Miercuri", "Joi", "Vineri", "Sâmbătă",
];

function startOfWeek(d: Date): Date {
  const date = new Date(d);
  const weekday = (date.getDay() + 6) % 7; // Monday=0
  date.setDate(date.getDate() - weekday);
  date.setHours(0, 0, 0, 0);
  return date;
}

function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

function ymd(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function normalise(s: string): string {
  return s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[şș]/g, "s")
    .replace(/[ţț]/g, "t");
}

function fullName(first?: string | null, last?: string | null): string {
  return `${(first ?? "").trim()} ${(last ?? "").trim()}`.trim();
}

// ── Internal helpers (shared across tools) ──────────────────────────────────

const RO_MONTHS = [
  "ianuarie", "februarie", "martie", "aprilie", "mai", "iunie",
  "iulie", "august", "septembrie", "octombrie", "noiembrie", "decembrie",
];

/** Romanian long-format date: "5 mai 2026". Returns "" when undefined. */
function roDate(d: Date | string | null | undefined): string {
  if (!d) return "";
  const date = typeof d === "string" ? new Date(d) : d;
  if (Number.isNaN(date.getTime())) return "";
  return `${date.getDate()} ${RO_MONTHS[date.getMonth()]} ${date.getFullYear()}`;
}

/** Trim "HH:MM:SS" → "HH:MM"; passes through anything else unchanged. */
function trimHm(t: string | null | undefined): string {
  if (!t) return "";
  return t.length >= 5 ? t.substring(0, 5) : t;
}

/** First/last day of the calendar month containing [d]. */
function monthBounds(d: Date): { start: string; end: string; nextStart: string } {
  const start = new Date(d.getFullYear(), d.getMonth(), 1);
  const nextStart = new Date(d.getFullYear(), d.getMonth() + 1, 1);
  const end = new Date(nextStart.getTime() - 1);
  return { start: ymd(start), end: ymd(end), nextStart: ymd(nextStart) };
}

/** PostgREST ilike-safe escape: literal `%` and `_` are protected. */
function escapeIlike(s: string): string {
  return s.replace(/%/g, "\\%").replace(/_/g, "\\_");
}

/** Cap a list at [max]; never return hundreds of rows to the model. */
function trim<T>(list: T[], max: number): T[] {
  return list.slice(0, Math.max(0, max));
}

/** Sum of `present + absent + motivated` over a window, derived once. */
function attendanceRate(present: number, total: number): number | null {
  if (total <= 0) return null;
  return Math.round((present / total) * 100);
}

/** Romanian display label for a `payment_cycles.status` + method pair. */
function paymentLabel(
  status: string | null | undefined,
  method?: string | null,
): string {
  const m = (method ?? "").trim().toUpperCase();
  const tail = m ? ` ${m}` : "";
  switch (status) {
    case "paid": return `Plată confirmată${tail}`;
    case "paid_advance": return `Achitat în avans${tail}`;
    case "due": return "Plată neconfirmată";
    case "overdue": return "Restant";
    case "cancelled": return "Anulat";
    default: return "—";
  }
}

/** Canonical workshop-type bucket so the model can group reliably. */
function workshopCategory(type: string | null | undefined): string {
  const t = (type ?? "").toLowerCase();
  if (t.includes("robotic")) return "Robotică";
  if (t.includes("lectur")) return "Lectură";
  if (t.includes("modela")) return "Modelare 3D";
  if (t.includes("tales") || t.includes("povestiri")) return "Povestiri";
  if (t.includes("desen") || t.includes("pictur") || t.includes("culoare")) {
    return "Desen & Pictură";
  }
  if (t.includes("program") || t.includes("ai") || t.includes("inteligenț")) {
    return "Programare & AI";
  }
  return (type ?? "Necategorizat").trim() || "Necategorizat";
}

/** Bulk name lookup keyed by id. Empty-input safe. */
async function fetchChildNames(
  admin: SupabaseClient,
  ids: string[],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (ids.length === 0) return out;
  const { data } = await admin
    .from("children")
    .select("id, first_name, last_name")
    .in("id", Array.from(new Set(ids)));
  for (
    const r of (data ?? []) as Array<
      { id: string; first_name: string | null; last_name: string | null }
    >
  ) {
    out.set(r.id, fullName(r.first_name, r.last_name));
  }
  return out;
}

async function fetchTrainerNames(
  admin: SupabaseClient,
  ids: string[],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const uniq = Array.from(new Set(ids.filter((s) => s)));
  if (uniq.length === 0) return out;
  const { data } = await admin
    .from("profiles")
    .select("id, first_name, last_name")
    .in("id", uniq);
  for (
    const r of (data ?? []) as Array<
      { id: string; first_name: string | null; last_name: string | null }
    >
  ) {
    out.set(r.id, fullName(r.first_name, r.last_name));
  }
  return out;
}

/** Best-effort name → trainer id resolver. Returns null on no match. */
async function findTrainerByName(
  admin: SupabaseClient,
  name: string,
): Promise<{ id: string; full: string } | null> {
  const q = (name ?? "").trim();
  if (q.length < 2) return null;
  const escaped = escapeIlike(q);
  const { data } = await admin
    .from("profiles")
    .select("id, first_name, last_name")
    .eq("role", "trainer")
    .or(`first_name.ilike.%${escaped}%,last_name.ilike.%${escaped}%`)
    .limit(5);
  const rows = (data ?? []) as Array<
    { id: string; first_name: string | null; last_name: string | null }
  >;
  if (rows.length === 0) return null;
  const target = normalise(q);
  const exact = rows.find((r) =>
    normalise(fullName(r.first_name, r.last_name)) === target
  );
  const picked = exact ?? rows[0];
  return { id: picked.id, full: fullName(picked.first_name, picked.last_name) };
}

async function toolGetDashboardSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const today = ymd(new Date());
  const weekStart = ymd(startOfWeek(new Date()));
  const weekEnd = ymd(addDays(startOfWeek(new Date()), 6));

  const [
    childrenActive,
    childrenInactive,
    workshopsToday,
    workshopsThisWeek,
    overdue,
    due,
  ] = await Promise.all([
    admin.from("children").select("id", { count: "exact", head: true }).eq("is_active", true),
    admin.from("children").select("id", { count: "exact", head: true }).eq("is_active", false),
    admin
      .from("scheduled_workshops")
      .select("id", { count: "exact", head: true })
      .eq("workshop_date", today)
      .eq("is_active", true),
    admin
      .from("scheduled_workshops")
      .select("id", { count: "exact", head: true })
      .gte("workshop_date", weekStart)
      .lte("workshop_date", weekEnd)
      .eq("is_active", true),
    admin
      .from("payment_cycles")
      .select("id, children!inner(payment_type)", { count: "exact", head: true })
      .eq("status", "overdue")
      .eq("children.payment_type", "paid"),
    admin
      .from("payment_cycles")
      .select("id, children!inner(payment_type)", { count: "exact", head: true })
      .eq("status", "due")
      .eq("children.payment_type", "paid"),
  ]);

  return {
    copii_activi: childrenActive.count ?? 0,
    copii_inactivi: childrenInactive.count ?? 0,
    ateliere_azi: workshopsToday.count ?? 0,
    ateliere_saptamana: workshopsThisWeek.count ?? 0,
    plati_restante: overdue.count ?? 0,
    plati_neconfirmate: due.count ?? 0,
  };
}

async function toolGetChildrenSummary(
  admin: SupabaseClient,
  args: { only_active?: boolean },
): Promise<Record<string, unknown>> {
  const onlyActive = args.only_active !== false;
  const q = admin.from("children").select("first_name, last_name, is_active");
  const { data } = onlyActive ? await q.eq("is_active", true) : await q;
  const rows = (data ?? []) as Array<
    { first_name: string | null; last_name: string | null; is_active: boolean }
  >;
  const active = rows.filter((r) => r.is_active).length;
  const inactive = rows.filter((r) => !r.is_active).length;
  const names = rows
    .filter((r) => !onlyActive || r.is_active)
    .map((r) => fullName(r.first_name, r.last_name))
    .filter((n) => n.length > 0)
    .sort()
    .slice(0, 50);
  return {
    total: rows.length,
    activi: active,
    inactivi: inactive,
    primele_nume: names,
    nota: rows.length > names.length
      ? `Lista a fost truncheată la ${names.length} nume.`
      : undefined,
  };
}

async function toolSearchChildByName(
  admin: SupabaseClient,
  args: { query: string },
): Promise<Record<string, unknown>> {
  const q = (args.query ?? "").trim();
  if (q.length < 2) return { results: [], nota: "Interogare prea scurtă." };
  const escaped = q.replace(/%/g, "\\%").replace(/_/g, "\\_");
  const { data } = await admin
    .from("children")
    .select(
      "first_name, last_name, birth_date, parent_name, parent_phone, is_active, payment_type",
    )
    .or(`first_name.ilike.%${escaped}%,last_name.ilike.%${escaped}%`)
    .limit(10);
  const rows = (data ?? []) as Array<{
    first_name: string | null;
    last_name: string | null;
    birth_date: string | null;
    parent_name: string | null;
    parent_phone: string | null;
    is_active: boolean;
    payment_type: string | null;
  }>;
  return {
    results: rows.map((r) => ({
      nume: fullName(r.first_name, r.last_name),
      activ: r.is_active,
      data_nasterii: r.birth_date,
      parinte: r.parent_name,
      telefon_parinte: r.parent_phone,
      tip_participare: r.payment_type === "free" ? "gratuit" : "platitor",
    })),
  };
}

async function findChildByName(
  admin: SupabaseClient,
  childName: string,
): Promise<{ id: string; full: string } | null> {
  const escaped = childName.trim().replace(/%/g, "\\%").replace(/_/g, "\\_");
  const { data } = await admin
    .from("children")
    .select("id, first_name, last_name")
    .or(`first_name.ilike.%${escaped}%,last_name.ilike.%${escaped}%`)
    .limit(5);
  const rows = (data ?? []) as Array<{
    id: string;
    first_name: string | null;
    last_name: string | null;
  }>;
  if (rows.length === 0) return null;
  const target = normalise(childName);
  const exact = rows.find((r) =>
    normalise(fullName(r.first_name, r.last_name)) === target
  );
  const picked = exact ?? rows[0];
  return { id: picked.id, full: fullName(picked.first_name, picked.last_name) };
}

async function toolGetChildDetails(
  admin: SupabaseClient,
  args: { child_name: string },
): Promise<Record<string, unknown>> {
  const child = await findChildByName(admin, args.child_name);
  if (!child) {
    return { eroare: `Nu am găsit niciun copil cu numele "${args.child_name}".` };
  }

  const [enrollments, lastAttendance, lastCycle, childMeta] = await Promise.all([
    admin
      .from("workshop_enrollments")
      .select("workshop_series!series_id(title, workshop_type, day_of_week, start_time, end_time)")
      .eq("child_id", child.id)
      .eq("is_active", true),
    admin
      .from("attendance")
      .select(
        "status, marked_at, scheduled_workshops!scheduled_workshop_id(title, workshop_date)",
      )
      .eq("child_id", child.id)
      .eq("is_archived", false)
      .order("marked_at", { ascending: false })
      .limit(1),
    admin
      .from("payment_cycles")
      .select("status, period_start, period_end, sessions_count, payment_method, paid_at")
      .eq("child_id", child.id)
      .order("created_at", { ascending: false })
      .limit(1),
    admin
      .from("children")
      .select("payment_type")
      .eq("id", child.id)
      .maybeSingle(),
  ]);
  const childMetaRow = (childMeta?.data ?? null) as { payment_type: string | null } | null;
  const tipParticipare =
    childMetaRow?.payment_type === "free" ? "gratuit" : "platitor";

  const enrollmentRows = (enrollments.data ?? []) as Array<{
    workshop_series: {
      title: string | null;
      workshop_type: string | null;
      day_of_week: string | null;
      start_time: string | null;
      end_time: string | null;
    } | null;
  }>;

  const ateliere = enrollmentRows
    .map((e) => e.workshop_series)
    .filter((w): w is NonNullable<typeof w> => w !== null)
    .map((w) => ({
      titlu: w.title,
      tip: w.workshop_type,
      zi: w.day_of_week,
      ora_start: w.start_time,
      ora_sfarsit: w.end_time,
    }));

  const attRows = (lastAttendance.data ?? []) as Array<{
    status: string | null;
    marked_at: string | null;
    scheduled_workshops: { title: string | null; workshop_date: string | null } | null;
  }>;
  const lastAtt = attRows[0];

  const cycleRows = (lastCycle.data ?? []) as Array<{
    status: string | null;
    period_start: string | null;
    period_end: string | null;
    sessions_count: number | null;
    payment_method: string | null;
    paid_at: string | null;
  }>;
  const lastPay = cycleRows[0];

  return {
    nume: child.full,
    tip_participare: tipParticipare,
    ateliere_active: ateliere,
    ultima_prezenta: lastAtt
      ? {
        status: lastAtt.status,
        data_atelierului: lastAtt.scheduled_workshops?.workshop_date,
        titlu_atelier: lastAtt.scheduled_workshops?.title,
      }
      : null,
    // For free participants the cycle exists informationally only and does
    // not represent a payment obligation — surface a different label so
    // the model does not narrate it as a financial event.
    ultimul_ciclu_plata: lastPay && tipParticipare !== "gratuit"
      ? {
        status: lastPay.status,
        perioada: `${lastPay.period_start} – ${lastPay.period_end}`,
        sedinte: lastPay.sessions_count,
        metoda: lastPay.payment_method,
        platit_la: lastPay.paid_at,
      }
      : null,
    nota_participare_gratuita: tipParticipare === "gratuit"
      ? "Copilul are participare gratuită. Nu se generează plăți, alerte sau cicluri financiare."
      : undefined,
  };
}

async function toolGetWorkshops(
  admin: SupabaseClient,
  args: { scope: string; from?: string; to?: string },
): Promise<Record<string, unknown>> {
  let from = "", to = "";
  const now = new Date();
  switch (args.scope) {
    case "today":
      from = ymd(now);
      to = ymd(now);
      break;
    case "this_week":
      from = ymd(startOfWeek(now));
      to = ymd(addDays(startOfWeek(now), 6));
      break;
    case "next_week":
      from = ymd(addDays(startOfWeek(now), 7));
      to = ymd(addDays(startOfWeek(now), 13));
      break;
    case "custom":
      from = (args.from ?? "").trim();
      to = (args.to ?? "").trim();
      if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) {
        return { eroare: "Format de date invalid. Folosește YYYY-MM-DD." };
      }
      break;
    default:
      return { eroare: "Scope nerecunoscut." };
  }

  const { data } = await admin
    .from("scheduled_workshops")
    .select(
      "title, workshop_type, workshop_date, day_of_week, start_time, end_time, " +
        "profiles!trainer_id(first_name, last_name)",
    )
    .eq("is_active", true)
    .gte("workshop_date", from)
    .lte("workshop_date", to)
    .order("workshop_date", { ascending: true })
    .order("start_time", { ascending: true });

  const rows = (data ?? []) as Array<{
    title: string | null;
    workshop_type: string | null;
    workshop_date: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
    profiles: { first_name: string | null; last_name: string | null } | null;
  }>;

  return {
    interval: { de_la: from, pana_la: to },
    total: rows.length,
    ateliere: rows.map((r) => ({
      titlu: r.title,
      tip: r.workshop_type,
      data: r.workshop_date,
      zi: r.day_of_week,
      ora_start: r.start_time,
      ora_sfarsit: r.end_time,
      trainer: r.profiles ? fullName(r.profiles.first_name, r.profiles.last_name) : null,
    })),
  };
}

async function toolGetAttendanceSummary(
  admin: SupabaseClient,
  args: { days?: number; child_name?: string },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 30, 1), 365);
  const since = ymd(addDays(new Date(), -days));

  let childId: string | null = null;
  let childFull: string | null = null;
  if (args.child_name) {
    const c = await findChildByName(admin, args.child_name);
    if (!c) {
      return { eroare: `Nu am găsit copilul "${args.child_name}".` };
    }
    childId = c.id;
    childFull = c.full;
  }

  async function countByStatus(status: string): Promise<number> {
    let q = admin
      .from("attendance")
      .select("id", { count: "exact", head: true })
      .eq("is_archived", false)
      .eq("status", status)
      .gte("marked_at", since);
    if (childId) q = q.eq("child_id", childId);
    const { count } = await q;
    return count ?? 0;
  }

  const [present, absent, motivated] = await Promise.all([
    countByStatus("present"),
    countByStatus("absent"),
    countByStatus("motivated"),
  ]);
  const total = present + absent + motivated;
  const ratePct = total === 0 ? 0 : Math.round((present / total) * 100);

  return {
    fereastra_zile: days,
    copil: childFull,
    total_inregistrari: total,
    prezente: present,
    absente: absent,
    motivate: motivated,
    rata_prezenta_procent: ratePct,
  };
}

async function toolGetPaymentsDue(
  admin: SupabaseClient,
  args: { only_overdue?: boolean },
): Promise<Record<string, unknown>> {
  const statuses = args.only_overdue ? ["overdue"] : ["due", "overdue"];
  // Series info joined so the model can present per-workshop context —
  // a child enrolled in 2 workshops may have a due cycle for Robotică
  // and be up-to-date for Engleză. Merging them into one line is wrong.
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "child_id, status, payment_method, period_start, period_end, " +
        "sessions_count, paid_at, confirmed_by, series_id, " +
        "children!inner(first_name, last_name, payment_type), " +
        "workshop_series!series_id(title)",
    )
    .in("status", statuses)
    .eq("children.payment_type", "paid")
    .order("period_start", { ascending: false })
    .limit(80);

  const rows = (data ?? []) as Array<{
    child_id: string;
    status: string | null;
    payment_method: string | null;
    period_start: string | null;
    period_end: string | null;
    sessions_count: number | null;
    paid_at: string | null;
    confirmed_by: string | null;
    series_id: string | null;
    children:
      | { first_name: string | null; last_name: string | null; payment_type: string | null }
      | null;
    workshop_series: { title: string | null } | null;
  }>;

  const overdue = rows.filter((r) => r.status === "overdue").length;
  const due = rows.filter((r) => r.status === "due").length;

  return {
    total: rows.length,
    restante: overdue,
    neconfirmate: due,
    detalii: rows.map((r) => ({
      copil: r.children
        ? fullName(r.children.first_name, r.children.last_name)
        : null,
      child_id: r.child_id,
      atelier: r.workshop_series?.title ?? null,
      status: r.status,
      metoda: (r.payment_method ?? "").toUpperCase() || null,
      perioada: `${r.period_start} – ${r.period_end}`,
      sedinte: r.sessions_count,
    })),
    nota:
      "Ciclurile de plată sunt INDEPENDENTE per atelier. Fiecare rând din " +
      "`detalii` include `atelier` — folosește-l în răspuns astfel încât " +
      "utilizatorul să vadă ce atelier are ciclu restant, nu doar copilul.",
  };
}

async function toolGetTrainersSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const { data: trainers } = await admin
    .from("profiles")
    .select("id, first_name, last_name")
    .eq("role", "trainer");

  const trainerRows = (trainers ?? []) as Array<
    { id: string; first_name: string | null; last_name: string | null }
  >;

  const counts = await Promise.all(trainerRows.map(async (t) => {
    const { count } = await admin
      .from("workshop_series")
      .select("id", { count: "exact", head: true })
      .eq("trainer_id", t.id)
      .eq("is_active", true);
    return { nume: fullName(t.first_name, t.last_name), ateliere_active: count ?? 0 };
  }));

  counts.sort((a, b) => b.ateliere_active - a.ateliere_active);

  return {
    total_traineri: trainerRows.length,
    traineri: counts,
  };
}

async function toolGetDemoWorkshopsSummary(
  admin: SupabaseClient,
  args: { scope?: string },
): Promise<Record<string, unknown>> {
  const scope = args.scope ?? "upcoming";
  const today = ymd(new Date());
  let q = admin
    .from("demo_workshops")
    .select("demo_date, status, start_time, end_time")
    .order("demo_date", { ascending: scope === "past" ? false : true })
    .limit(50);
  if (scope === "upcoming") q = q.gte("demo_date", today);
  if (scope === "past") q = q.lt("demo_date", today);

  const { data } = await q;
  const rows = (data ?? []) as Array<{
    demo_date: string | null;
    status: string | null;
    start_time: string | null;
    end_time: string | null;
  }>;
  const byStatus: Record<string, number> = {};
  for (const r of rows) {
    const s = r.status ?? "necunoscut";
    byStatus[s] = (byStatus[s] ?? 0) + 1;
  }
  return {
    scope,
    total: rows.length,
    pe_status: byStatus,
    proximele: rows.slice(0, 10).map((r) => ({
      data: r.demo_date,
      status: r.status,
      ora_start: r.start_time,
      ora_sfarsit: r.end_time,
    })),
  };
}

// ── Analytics tools ─────────────────────────────────────────────────────────

async function toolGetTopChildrenAttendance(
  admin: SupabaseClient,
  args: { days?: number; limit?: number },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 90, 7), 365);
  const limit = Math.min(Math.max(args.limit ?? 10, 1), 50);
  const since = ymd(addDays(new Date(), -days));

  const { data: attRows } = await admin
    .from("attendance")
    .select("child_id, status")
    .eq("is_archived", false)
    .gte("marked_at", since);

  const rows = (attRows ?? []) as Array<
    { child_id: string; status: string | null }
  >;

  type Bucket = {
    present: number;
    absent: number;
    motivated: number;
    total: number;
  };
  const buckets = new Map<string, Bucket>();
  for (const r of rows) {
    const b = buckets.get(r.child_id) ??
      { present: 0, absent: 0, motivated: 0, total: 0 };
    if (r.status === "present") b.present += 1;
    else if (r.status === "absent") b.absent += 1;
    else if (r.status === "motivated") b.motivated += 1;
    b.total = b.present + b.absent + b.motivated;
    buckets.set(r.child_id, b);
  }

  if (buckets.size === 0) {
    return { fereastra_zile: days, copii: [], nota: "Fără înregistrări de prezență în această fereastră." };
  }

  const ids = Array.from(buckets.keys());
  const { data: kids } = await admin
    .from("children")
    .select("id, first_name, last_name, is_active")
    .in("id", ids);

  const names = new Map<
    string,
    { name: string; active: boolean }
  >();
  for (
    const k of (kids ?? []) as Array<
      { id: string; first_name: string | null; last_name: string | null; is_active: boolean }
    >
  ) {
    names.set(k.id, {
      name: fullName(k.first_name, k.last_name),
      active: k.is_active,
    });
  }

  const ranked = ids
    .map((id) => {
      const b = buckets.get(id)!;
      const meta = names.get(id) ?? { name: "Necunoscut", active: false };
      const rate = b.total === 0 ? 0 : Math.round((b.present / b.total) * 100);
      return {
        nume: meta.name,
        activ: meta.active,
        total_sedinte: b.total,
        prezente: b.present,
        absente: b.absent,
        motivate: b.motivated,
        rata_prezenta_procent: rate,
      };
    })
    .filter((r) => r.total_sedinte >= 1)
    .sort((a, b) =>
      b.rata_prezenta_procent - a.rata_prezenta_procent ||
      b.total_sedinte - a.total_sedinte ||
      a.nume.localeCompare(b.nume)
    )
    .slice(0, limit);

  return {
    fereastra_zile: days,
    total_copii_analizati: buckets.size,
    top: ranked,
  };
}

async function toolGetWorkshopAttendanceAnalysis(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const { data: attRows } = await admin
    .from("attendance")
    .select(
      "status, scheduled_workshops!scheduled_workshop_id(title, series_id, recurring_series_id, workshop_type)",
    )
    .eq("is_archived", false);

  const rows = (attRows ?? []) as Array<{
    status: string | null;
    scheduled_workshops: {
      title: string | null;
      series_id: string | null;
      recurring_series_id: string | null;
      workshop_type: string | null;
    } | null;
  }>;

  type Bucket = {
    title: string;
    type: string | null;
    present: number;
    absent: number;
    motivated: number;
    total: number;
  };
  const buckets = new Map<string, Bucket>();
  for (const r of rows) {
    const sw = r.scheduled_workshops;
    if (!sw) continue;
    const key = sw.series_id ?? sw.recurring_series_id ?? sw.title ?? "unknown";
    const b = buckets.get(key) ?? {
      title: sw.title ?? "Atelier",
      type: sw.workshop_type,
      present: 0,
      absent: 0,
      motivated: 0,
      total: 0,
    };
    if (r.status === "present") b.present += 1;
    else if (r.status === "absent") b.absent += 1;
    else if (r.status === "motivated") b.motivated += 1;
    b.total = b.present + b.absent + b.motivated;
    buckets.set(key, b);
  }

  const allAnalysis = Array.from(buckets.values())
    .map((b) => ({
      titlu: b.title,
      tip: b.type,
      total_inregistrari: b.total,
      prezente: b.present,
      absente: b.absent,
      motivate: b.motivated,
      rata_prezenta_procent: b.total === 0
        ? 0
        : Math.round((b.present / b.total) * 100),
    }));

  // Only entries with a meaningful sample size compete for best/worst.
  // Anything with <3 marked sessions is excluded from the ranking — a
  // single 100%-present row should never be reported as "best workshop".
  const MIN_SAMPLE = 3;
  const ranked = allAnalysis.filter((a) => a.total_inregistrari >= MIN_SAMPLE);
  const skipped = allAnalysis.length - ranked.length;
  ranked.sort((a, b) =>
    b.rata_prezenta_procent - a.rata_prezenta_procent ||
    b.total_inregistrari - a.total_inregistrari
  );
  const worst = [...ranked].sort((a, b) =>
    a.rata_prezenta_procent - b.rata_prezenta_procent ||
    b.total_inregistrari - a.total_inregistrari
  )[0];
  const best = ranked[0];

  return {
    total_ateliere_cu_inregistrari: allAnalysis.length,
    total_ateliere_in_ranking: ranked.length,
    ateliere_excluse_din_ranking_set_mic: skipped,
    cel_mai_bun_atelier: best ?? null,
    cel_mai_slab_atelier: worst ?? null,
    ateliere: ranked,
    nota: skipped > 0
      ? `${skipped} ateliere au mai puțin de ${MIN_SAMPLE} ședințe marcate ` +
        "și sunt excluse din ranking pentru a evita rezultate înșelătoare."
      : undefined,
  };
}

async function toolGetFinancialSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const now = new Date();
  const monthStart = ymd(new Date(now.getFullYear(), now.getMonth(), 1));
  const nextMonthStart = ymd(
    new Date(now.getFullYear(), now.getMonth() + 1, 1),
  );

  // Every payment_cycles read joins `children!inner(payment_type)` and
  // restricts to `payment_type = 'paid'` so that free participants are
  // excluded from every financial figure.
  const [dueRes, overdueRes, paidThisMonthRes, outstandingRes] =
    await Promise.all([
      admin
        .from("payment_cycles")
        .select("id, children!inner(payment_type)", { count: "exact", head: true })
        .eq("status", "due")
        .eq("children.payment_type", "paid"),
      admin
        .from("payment_cycles")
        .select("id, children!inner(payment_type)", { count: "exact", head: true })
        .eq("status", "overdue")
        .eq("children.payment_type", "paid"),
      admin
        .from("payment_cycles")
        .select("id, children!inner(payment_type)", { count: "exact", head: true })
        .eq("status", "paid")
        .eq("children.payment_type", "paid")
        .gte("paid_at", monthStart)
        .lt("paid_at", nextMonthStart),
      admin
        .from("payment_cycles")
        .select(
          "child_id, sessions_count, status, period_start, period_end, " +
            "series_id, " +
            "children!inner(payment_type), " +
            "workshop_series!series_id(title)",
        )
        .in("status", ["due", "overdue"])
        .eq("children.payment_type", "paid"),
    ]);

  const outstanding = (outstandingRes.data ?? []) as Array<{
    child_id: string;
    sessions_count: number | null;
    status: string | null;
    period_start: string | null;
    period_end: string | null;
    series_id: string | null;
    workshop_series: { title: string | null } | null;
  }>;

  type ChildAgg = {
    cycles: number;
    sessions: number;
    overdue: number;
    earliestPeriod: string | null;
    series: Set<string>; // series titles the child owes for
  };
  const perChild = new Map<string, ChildAgg>();
  const perSeries = new Map<string, { cycles: number; overdue: number }>();
  for (const r of outstanding) {
    const b = perChild.get(r.child_id) ??
      { cycles: 0, sessions: 0, overdue: 0, earliestPeriod: null, series: new Set<string>() };
    b.cycles += 1;
    b.sessions += r.sessions_count ?? 0;
    if (r.status === "overdue") b.overdue += 1;
    if (r.period_start &&
        (b.earliestPeriod === null || r.period_start < b.earliestPeriod)) {
      b.earliestPeriod = r.period_start;
    }
    const title = r.workshop_series?.title ?? "Fără atelier";
    b.series.add(title);
    perChild.set(r.child_id, b);
    const s = perSeries.get(title) ?? { cycles: 0, overdue: 0 };
    s.cycles += 1;
    if (r.status === "overdue") s.overdue += 1;
    perSeries.set(title, s);
  }

  const childIds = Array.from(perChild.keys());
  let topChildren: Array<Record<string, unknown>> = [];
  if (childIds.length > 0) {
    const { data: kids } = await admin
      .from("children")
      .select("id, first_name, last_name")
      .in("id", childIds);
    const names = new Map<string, string>();
    for (
      const k of (kids ?? []) as Array<
        { id: string; first_name: string | null; last_name: string | null }
      >
    ) {
      names.set(k.id, fullName(k.first_name, k.last_name));
    }
    topChildren = childIds
      .map((id) => {
        const b = perChild.get(id)!;
        return {
          nume: names.get(id) ?? "Necunoscut",
          cicluri_neincasate: b.cycles,
          sedinte_neincasate: b.sessions,
          restante: b.overdue,
          cea_mai_veche_perioada: b.earliestPeriod,
          ateliere_cu_cicluri_neincasate: Array.from(b.series).sort(),
        };
      })
      .sort((a, b) =>
        (b.restante as number) - (a.restante as number) ||
        (b.cicluri_neincasate as number) - (a.cicluri_neincasate as number) ||
        (b.sedinte_neincasate as number) - (a.sedinte_neincasate as number)
      )
      .slice(0, 5);
  }

  const totalOutstandingSessions = outstanding.reduce(
    (s, r) => s + (r.sessions_count ?? 0),
    0,
  );

  const perSeriesBreakdown = Array.from(perSeries.entries())
    .map(([title, s]) => ({
      atelier: title,
      cicluri_neincasate: s.cycles,
      restante: s.overdue,
    }))
    .sort((a, b) => b.cicluri_neincasate - a.cicluri_neincasate);

  return {
    cicluri_neincasate: dueRes.count ?? 0,
    cicluri_restante: overdueRes.count ?? 0,
    cicluri_platite_luna_aceasta: paidThisMonthRes.count ?? 0,
    total_sedinte_neincasate: totalOutstandingSessions,
    nota_suma:
      "Aplicația nu stochează preț per sesiune; o sumă monetară exactă nu poate fi calculată. Folosește total_sedinte_neincasate ca proxy.",
    copii_cu_cele_mai_multe_plati_neincasate: topChildren,
    cicluri_neincasate_per_atelier: perSeriesBreakdown,
    nota_atelier:
      "Ciclurile de plată sunt per atelier. Când răspunzi, precizează care copii au restanțe pe care ateliere — nu combina Robotică cu Engleză într-un total agregat pentru același copil.",
  };
}

async function toolGetRiskChildren(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const days = 60;
  const since = ymd(addDays(new Date(), -days));

  const [attRes, overdueRes, kidsRes] = await Promise.all([
    admin
      .from("attendance")
      .select("child_id, status")
      .eq("is_archived", false)
      .gte("marked_at", since),
    admin
      .from("payment_cycles")
      .select("child_id, sessions_count, children!inner(payment_type)")
      .eq("status", "overdue")
      // Free participants never appear in risk-by-finance buckets.
      .eq("children.payment_type", "paid"),
    admin
      .from("children")
      .select("id, first_name, last_name")
      .eq("is_active", true),
  ]);

  type Bucket = {
    present: number;
    absent: number;
    motivated: number;
    total: number;
  };
  const att = new Map<string, Bucket>();
  for (
    const r of (attRes.data ?? []) as Array<
      { child_id: string; status: string | null }
    >
  ) {
    const b = att.get(r.child_id) ??
      { present: 0, absent: 0, motivated: 0, total: 0 };
    if (r.status === "present") b.present += 1;
    else if (r.status === "absent") b.absent += 1;
    else if (r.status === "motivated") b.motivated += 1;
    b.total = b.present + b.absent + b.motivated;
    att.set(r.child_id, b);
  }

  const overdueByChild = new Map<string, number>();
  for (
    const r of (overdueRes.data ?? []) as Array<
      { child_id: string; sessions_count: number | null }
    >
  ) {
    overdueByChild.set(
      r.child_id,
      (overdueByChild.get(r.child_id) ?? 0) + 1,
    );
  }

  const risky = [] as Array<Record<string, unknown>>;
  for (
    const k of (kidsRes.data ?? []) as Array<
      { id: string; first_name: string | null; last_name: string | null }
    >
  ) {
    const a = att.get(k.id) ?? { present: 0, absent: 0, motivated: 0, total: 0 };
    const overdueCount = overdueByChild.get(k.id) ?? 0;
    const rate = a.total === 0 ? null : Math.round((a.present / a.total) * 100);

    const reasons: string[] = [];
    const lowAttendance = rate !== null && a.total >= 3 && rate < 50;
    const manyAbsences = a.absent > 3;
    const overdue = overdueCount > 0;

    if (lowAttendance) reasons.push(`prezență sub 50% (${rate}%)`);
    if (manyAbsences) {
      reasons.push(`${a.absent} absențe în ultimele ${days} de zile`);
    }
    if (overdue) {
      reasons.push(
        overdueCount === 1
          ? "1 plată restantă"
          : `${overdueCount} plăți restante`,
      );
    }

    if (reasons.length === 0) continue;

    // Severity score: overdue dominates, then low rate, then absence count.
    const severity = (overdue ? 1000 : 0) +
      (rate !== null ? Math.max(0, 100 - rate) : 0) +
      a.absent * 2;

    risky.push({
      nume: fullName(k.first_name, k.last_name),
      total_sedinte: a.total,
      prezente: a.present,
      absente: a.absent,
      motivate: a.motivated,
      rata_prezenta_procent: rate,
      plati_restante: overdueCount,
      motive: reasons,
      _severity: severity,
    });
  }

  risky.sort(
    (a, b) => (b._severity as number) - (a._severity as number),
  );
  // Strip the helper field before returning.
  const cleaned = risky.map((r) => {
    const { _severity, ...rest } = r as Record<string, unknown>;
    return rest;
  });

  return {
    fereastra_zile: days,
    criterii: {
      rata_prezenta_sub: 50,
      absente_peste: 3,
      include_plati_restante: true,
    },
    total_copii_in_risc: cleaned.length,
    copii_in_risc: cleaned.slice(0, 20),
  };
}

async function toolGetParentAccountStatus(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const [
    parentCountRes,
    openTokensRes,
    consumedTokensRes,
    linkedChildrenRes,
    allActiveKidsRes,
  ] = await Promise.all([
    admin
      .from("profiles")
      .select("id", { count: "exact", head: true })
      .eq("role", "parent"),
    admin
      .from("parent_setup_tokens")
      .select("parent_id, email, created_at")
      .is("consumed_at", null),
    admin
      .from("parent_setup_tokens")
      .select("parent_id")
      .not("consumed_at", "is", null),
    admin
      .from("child_parents")
      .select("child_id"),
    admin
      .from("children")
      .select("id, first_name, last_name")
      .eq("is_active", true),
  ]);

  const activatedSet = new Set<string>();
  for (
    const r of (consumedTokensRes.data ?? []) as Array<{ parent_id: string }>
  ) {
    activatedSet.add(r.parent_id);
  }

  const pendingByParent = new Map<
    string,
    { email: string | null; created_at: string | null }
  >();
  for (
    const t of (openTokensRes.data ?? []) as Array<
      { parent_id: string; email: string | null; created_at: string | null }
    >
  ) {
    if (activatedSet.has(t.parent_id)) continue;
    const existing = pendingByParent.get(t.parent_id);
    if (
      !existing ||
      (t.created_at && (existing.created_at ?? "") < t.created_at)
    ) {
      pendingByParent.set(t.parent_id, {
        email: t.email,
        created_at: t.created_at,
      });
    }
  }

  const pendingIds = Array.from(pendingByParent.keys());
  let pendingDetails: Array<Record<string, unknown>> = [];
  if (pendingIds.length > 0) {
    const { data: profiles } = await admin
      .from("profiles")
      .select("id, first_name, last_name")
      .in("id", pendingIds);
    const names = new Map<string, string>();
    for (
      const p of (profiles ?? []) as Array<
        { id: string; first_name: string | null; last_name: string | null }
      >
    ) {
      names.set(p.id, fullName(p.first_name, p.last_name));
    }
    pendingDetails = pendingIds.map((id) => {
      const t = pendingByParent.get(id)!;
      return {
        nume: names.get(id) ?? "Necunoscut",
        email: t.email,
        invitatie_trimisa_la: t.created_at,
      };
    });
  }

  const linkedSet = new Set<string>();
  for (
    const r of (linkedChildrenRes.data ?? []) as Array<{ child_id: string }>
  ) {
    linkedSet.add(r.child_id);
  }
  const unlinked: Array<Record<string, unknown>> = [];
  for (
    const k of (allActiveKidsRes.data ?? []) as Array<
      { id: string; first_name: string | null; last_name: string | null }
    >
  ) {
    if (!linkedSet.has(k.id)) {
      unlinked.push({ nume: fullName(k.first_name, k.last_name) });
    }
  }

  return {
    total_parinti: parentCountRes.count ?? 0,
    parinti_activati: activatedSet.size,
    invitatii_neutilizate: pendingDetails.length,
    detalii_invitatii_neutilizate: pendingDetails.slice(0, 20),
    copii_activi_fara_parinte_asociat: unlinked.length,
    detalii_copii_fara_parinte: unlinked.slice(0, 20),
  };
}

// ── Overview / dashboard ────────────────────────────────────────────────────

async function toolGetCenterOverview(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const [dash, fin, risk, paymentTypes, missing, trainerLoad, progressSummary, materialsSummary, amountSummary] =
    await Promise.all([
      toolGetDashboardSummary(admin),
      toolGetFinancialSummary(admin),
      toolGetRiskChildren(admin),
      toolGetPaymentTypeSummary(admin),
      toolGetChildrenMissingProfileData(admin),
      toolGetTrainerChildrenSummary(admin),
      toolGetProgressSummary(admin),
      toolGetMaterialsSummary(admin),
      toolGetPaymentAmountSummary(admin, {}),
    ]);
  return {
    operational: dash,
    financiar: {
      cicluri_neincasate: fin.cicluri_neincasate,
      cicluri_restante: fin.cicluri_restante,
      cicluri_platite_luna_aceasta: fin.cicluri_platite_luna_aceasta,
      suma_incasata: amountSummary.suma_incasata,
      suma_restanta: amountSummary.suma_restanta,
      nota_suma: amountSummary.nota,
    },
    tip_participare: {
      copii_platitori_total: paymentTypes.copii_platitori_total,
      copii_gratuiti_total: paymentTypes.copii_gratuiti_total,
    },
    risc: { total_copii_in_risc: risk.total_copii_in_risc },
    igiena_date_copii: {
      fara_data_nasterii: (missing.fara_data_nasterii as { numar?: number })?.numar ?? 0,
      fara_telefon_parinte: (missing.fara_telefon_parinte as { numar?: number })?.numar ?? 0,
      fara_atelier: (missing.fara_atelier_asignat as { numar?: number })?.numar ?? 0,
    },
    incarcare_traineri: (trainerLoad.traineri as Array<Record<string, unknown>>)?.slice(0, 5) ?? [],
    progres: progressSummary.nota
      ? { nota: progressSummary.nota }
      : {
          total: progressSummary.total,
          luna_curenta: progressSummary.luna_curenta,
          pe_status: progressSummary.pe_status,
        },
    materiale: materialsSummary.nota
      ? { nota: materialsSummary.nota }
      : {
          total_active: materialsSummary.total_active,
          incarcate_luna: materialsSummary.incarcate_luna,
        },
    nota:
      "Sumar consolidat al stării centrului. Pentru detalii folosește tool-uri specifice.",
  };
}

async function toolGetTodaySummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const today = ymd(new Date());
  const [workshops, attMarked, demoToday] = await Promise.all([
    admin
      .from("scheduled_workshops")
      .select(
        "title, workshop_type, start_time, end_time, " +
          "profiles!trainer_id(first_name, last_name)",
      )
      .eq("workshop_date", today)
      .eq("is_active", true)
      .order("start_time"),
    admin
      .from("attendance")
      .select("id", { count: "exact", head: true })
      .gte("marked_at", `${today}T00:00:00`)
      .lt("marked_at", `${today}T23:59:59`)
      .eq("is_archived", false),
    admin
      .from("demo_workshops")
      .select("id", { count: "exact", head: true })
      .eq("demo_date", today),
  ]);
  const wsRows = (workshops.data ?? []) as Array<{
    title: string | null;
    workshop_type: string | null;
    start_time: string | null;
    end_time: string | null;
    profiles: { first_name: string | null; last_name: string | null } | null;
  }>;
  return {
    data: roDate(new Date()),
    ateliere_azi: wsRows.length,
    detalii_ateliere: wsRows.map((r) => ({
      titlu: r.title,
      categoria: workshopCategory(r.workshop_type),
      interval: `${trimHm(r.start_time)} – ${trimHm(r.end_time)}`,
      trainer: r.profiles ? fullName(r.profiles.first_name, r.profiles.last_name) : null,
    })),
    prezente_marcate_azi: attMarked.count ?? 0,
    ateliere_demo_azi: demoToday.count ?? 0,
  };
}

async function toolGetWeekSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const weekStart = ymd(startOfWeek(new Date()));
  const weekEnd = ymd(addDays(startOfWeek(new Date()), 6));
  const [workshops, attendance, demos] = await Promise.all([
    admin
      .from("scheduled_workshops")
      .select("id", { count: "exact", head: true })
      .gte("workshop_date", weekStart)
      .lte("workshop_date", weekEnd)
      .eq("is_active", true),
    admin
      .from("attendance")
      .select("status")
      .gte("marked_at", `${weekStart}T00:00:00`)
      .lte("marked_at", `${weekEnd}T23:59:59`)
      .eq("is_archived", false),
    admin
      .from("demo_workshops")
      .select("id", { count: "exact", head: true })
      .gte("demo_date", weekStart)
      .lte("demo_date", weekEnd),
  ]);
  const att = (attendance.data ?? []) as Array<{ status: string | null }>;
  const present = att.filter((r) => r.status === "present").length;
  const absent = att.filter((r) => r.status === "absent").length;
  const motivated = att.filter((r) => r.status === "motivated").length;
  return {
    interval: { de_la: weekStart, pana_la: weekEnd },
    ateliere_in_saptamana: workshops.count ?? 0,
    prezente: present,
    absente: absent,
    motivate: motivated,
    rata_prezenta_procent: attendanceRate(present, present + absent + motivated),
    ateliere_demo: demos.count ?? 0,
  };
}

async function toolGetMonthSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const { start, end } = monthBounds(new Date());
  const [workshops, attendance, paidThisMonth, newKids] = await Promise.all([
    admin
      .from("scheduled_workshops")
      .select("id", { count: "exact", head: true })
      .gte("workshop_date", start)
      .lte("workshop_date", end)
      .eq("is_active", true),
    admin
      .from("attendance")
      .select("status")
      .gte("marked_at", `${start}T00:00:00`)
      .lte("marked_at", `${end}T23:59:59`)
      .eq("is_archived", false),
    admin
      .from("payment_cycles")
      .select("id, children!inner(payment_type)", { count: "exact", head: true })
      .eq("status", "paid")
      .eq("children.payment_type", "paid")
      .gte("paid_at", start)
      .lte("paid_at", `${end}T23:59:59`),
    admin
      .from("children")
      .select("id", { count: "exact", head: true })
      .gte("created_at", start),
  ]);
  const att = (attendance.data ?? []) as Array<{ status: string | null }>;
  const present = att.filter((r) => r.status === "present").length;
  const absent = att.filter((r) => r.status === "absent").length;
  const motivated = att.filter((r) => r.status === "motivated").length;
  return {
    interval: { de_la: start, pana_la: end },
    ateliere_luna: workshops.count ?? 0,
    prezente: present,
    absente: absent,
    motivate: motivated,
    rata_prezenta_procent: attendanceRate(present, present + absent + motivated),
    cicluri_platite_luna: paidThisMonth.count ?? 0,
    copii_inscrisi_luna: newKids.count ?? 0,
  };
}

async function toolGetImportantAlerts(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const today = ymd(new Date());
  const [overdueRes, missingTrainerRes, missingChildrenRes, demoUpcomingRes] =
    await Promise.all([
      admin
        .from("payment_cycles")
        .select("id, children!inner(payment_type)", { count: "exact", head: true })
        .eq("status", "overdue")
        .eq("children.payment_type", "paid"),
      admin
        .from("scheduled_workshops")
        .select("id", { count: "exact", head: true })
        .is("trainer_id", null)
        .gte("workshop_date", today)
        .eq("is_active", true),
      admin
        .from("workshop_series")
        .select("id, title")
        .eq("is_active", true),
      admin
        .from("demo_workshops")
        .select("id", { count: "exact", head: true })
        .gte("demo_date", today),
    ]);
  // Active series without active enrollment
  let seriesWithoutChildren = 0;
  const series = (missingChildrenRes.data ?? []) as Array<
    { id: string; title: string | null }
  >;
  if (series.length > 0) {
    const ids = series.map((s) => s.id);
    const { data: enrollments } = await admin
      .from("workshop_enrollments")
      .select("series_id")
      .in("series_id", ids)
      .eq("is_active", true);
    const withChildren = new Set(
      ((enrollments ?? []) as Array<{ series_id: string }>).map((e) => e.series_id),
    );
    seriesWithoutChildren = series.filter((s) => !withChildren.has(s.id)).length;
  }
  const alerts: string[] = [];
  if ((overdueRes.count ?? 0) > 0) {
    alerts.push(`${overdueRes.count} cicluri de plată restante.`);
  }
  if ((missingTrainerRes.count ?? 0) > 0) {
    alerts.push(`${missingTrainerRes.count} ateliere viitoare fără trainer asignat.`);
  }
  if (seriesWithoutChildren > 0) {
    alerts.push(`${seriesWithoutChildren} serii active fără copii înscriși.`);
  }
  if ((demoUpcomingRes.count ?? 0) > 0) {
    alerts.push(`${demoUpcomingRes.count} ateliere demo programate.`);
  }
  return {
    numar_alerte: alerts.length,
    alerte: alerts,
    detalii: {
      plati_restante: overdueRes.count ?? 0,
      ateliere_fara_trainer: missingTrainerRes.count ?? 0,
      serii_fara_copii: seriesWithoutChildren,
      demo_viitoare: demoUpcomingRes.count ?? 0,
    },
  };
}

async function toolGetDataQualityIssues(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const today = ymd(new Date());
  const [
    missingBirth,
    missingParent,
    workshopsNoTrainer,
    seriesNoTrainer,
    paymentsBoth,
  ] = await Promise.all([
    admin
      .from("children")
      .select("id", { count: "exact", head: true })
      .is("birth_date", null)
      .eq("is_active", true),
    admin
      .from("children")
      .select("id", { count: "exact", head: true })
      .is("parent_phone", null)
      .eq("is_active", true),
    admin
      .from("scheduled_workshops")
      .select("id", { count: "exact", head: true })
      .is("trainer_id", null)
      .gte("workshop_date", today)
      .eq("is_active", true),
    admin
      .from("workshop_series")
      .select("id", { count: "exact", head: true })
      .is("trainer_id", null)
      .eq("is_active", true),
    admin
      .from("payment_cycles")
      .select("id, sessions_count, status, child_id, children!inner(payment_type)")
      .in("status", ["due", "overdue"])
      .eq("children.payment_type", "paid"),
  ]);

  // Duplicate child candidates: same first+last name, both active.
  const { data: kidsRows } = await admin
    .from("children")
    .select("id, first_name, last_name")
    .eq("is_active", true);
  const kids = (kidsRows ?? []) as Array<
    { id: string; first_name: string | null; last_name: string | null }
  >;
  const byKey = new Map<string, string[]>();
  for (const k of kids) {
    const key = normalise(fullName(k.first_name, k.last_name));
    if (!key) continue;
    if (!byKey.has(key)) byKey.set(key, []);
    byKey.get(key)!.push(k.id);
  }
  const duplicates = Array.from(byKey.entries())
    .filter(([, ids]) => ids.length > 1)
    .map(([nume]) => ({ nume_normalizat: nume, intrari: byKey.get(nume)!.length }));

  // Active children with no active enrollment.
  const { data: activeEnroll } = await admin
    .from("workshop_enrollments")
    .select("child_id")
    .eq("is_active", true);
  const enrolled = new Set(
    ((activeEnroll ?? []) as Array<{ child_id: string }>).map((r) => r.child_id),
  );
  const childrenWithoutWorkshop = kids.filter((k) => !enrolled.has(k.id)).length;

  // Suspicious payment cycles: sessions_count == 0 yet due/overdue.
  const susPayments = (paymentsBoth.data ?? []) as Array<
    { sessions_count: number | null; status: string | null }
  >;
  const zeroSessionDueCount = susPayments.filter(
    (r) => (r.sessions_count ?? 0) === 0,
  ).length;

  return {
    copii_fara_data_nasterii: missingBirth.count ?? 0,
    copii_fara_telefon_parinte: missingParent.count ?? 0,
    ateliere_viitoare_fara_trainer: workshopsNoTrainer.count ?? 0,
    serii_active_fara_trainer: seriesNoTrainer.count ?? 0,
    copii_activi_fara_atelier: childrenWithoutWorkshop,
    posibili_copii_duplicat: trim(duplicates, 10),
    cicluri_plata_suspecte_zero_sedinte: zeroSessionDueCount,
  };
}

// ── Children variants ───────────────────────────────────────────────────────

async function toolGetChildProfile(
  admin: SupabaseClient,
  args: { child_name: string },
): Promise<Record<string, unknown>> {
  // Alias for get_child_details — same shape, kept so OpenAI can pick a
  // semantically clearer name.
  return await toolGetChildDetails(admin, args);
}

async function toolGetChildActiveWorkshops(
  admin: SupabaseClient,
  args: { child_name: string },
): Promise<Record<string, unknown>> {
  const child = await findChildByName(admin, args.child_name);
  if (!child) return { eroare: `Nu am găsit copilul "${args.child_name}".` };
  const { data } = await admin
    .from("workshop_enrollments")
    .select(
      "workshop_series!series_id(title, workshop_type, day_of_week, start_time, end_time, profiles!trainer_id(first_name, last_name))",
    )
    .eq("child_id", child.id)
    .eq("is_active", true);
  const rows = (data ?? []) as Array<{
    workshop_series: {
      title: string | null;
      workshop_type: string | null;
      day_of_week: string | null;
      start_time: string | null;
      end_time: string | null;
      profiles: { first_name: string | null; last_name: string | null } | null;
    } | null;
  }>;
  return {
    copil: child.full,
    ateliere: rows
      .map((r) => r.workshop_series)
      .filter((w): w is NonNullable<typeof w> => w !== null)
      .map((w) => ({
        titlu: w.title,
        categoria: workshopCategory(w.workshop_type),
        zi: w.day_of_week,
        interval: `${trimHm(w.start_time)} – ${trimHm(w.end_time)}`,
        trainer: w.profiles
          ? fullName(w.profiles.first_name, w.profiles.last_name)
          : null,
      })),
  };
}

async function toolGetChildRecentActivity(
  admin: SupabaseClient,
  args: { child_name: string; limit?: number },
): Promise<Record<string, unknown>> {
  const child = await findChildByName(admin, args.child_name);
  if (!child) return { eroare: `Nu am găsit copilul "${args.child_name}".` };
  const limit = Math.min(Math.max(args.limit ?? 10, 1), 30);
  const { data } = await admin
    .from("attendance")
    .select(
      "status, observation, marked_at, " +
        "scheduled_workshops!scheduled_workshop_id(title, workshop_date)",
    )
    .eq("child_id", child.id)
    .eq("is_archived", false)
    .order("marked_at", { ascending: false })
    .limit(limit);
  const rows = (data ?? []) as Array<{
    status: string | null;
    observation: string | null;
    marked_at: string | null;
    scheduled_workshops: { title: string | null; workshop_date: string | null } | null;
  }>;
  return {
    copil: child.full,
    inregistrari_recente: rows.map((r) => ({
      data: r.scheduled_workshops?.workshop_date,
      atelier: r.scheduled_workshops?.title,
      status: r.status,
      observatie: r.observation && r.observation.trim().length > 0
        ? r.observation
        : null,
    })),
  };
}

async function toolGetChildrenWithoutActiveWorkshop(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const [kidsRes, enrollRes] = await Promise.all([
    admin
      .from("children")
      .select("id, first_name, last_name")
      .eq("is_active", true),
    admin
      .from("workshop_enrollments")
      .select("child_id")
      .eq("is_active", true),
  ]);
  const enrolled = new Set(
    ((enrollRes.data ?? []) as Array<{ child_id: string }>).map((r) => r.child_id),
  );
  const kids = (kidsRes.data ?? []) as Array<
    { id: string; first_name: string | null; last_name: string | null }
  >;
  const out = kids
    .filter((k) => !enrolled.has(k.id))
    .map((k) => fullName(k.first_name, k.last_name))
    .filter((n) => n.length > 0)
    .sort();
  return {
    total: out.length,
    copii: trim(out, limit),
  };
}

async function toolGetChildrenWithMultipleWorkshops(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const { data } = await admin
    .from("workshop_enrollments")
    .select("child_id")
    .eq("is_active", true);
  const counts = new Map<string, number>();
  for (const r of (data ?? []) as Array<{ child_id: string }>) {
    counts.set(r.child_id, (counts.get(r.child_id) ?? 0) + 1);
  }
  const multi = Array.from(counts.entries()).filter(([, n]) => n > 1);
  const names = await fetchChildNames(admin, multi.map(([id]) => id));
  const out = multi
    .map(([id, n]) => ({
      nume: names.get(id) ?? "Necunoscut",
      ateliere_active: n,
    }))
    .sort((a, b) => b.ateliere_active - a.ateliere_active)
    .filter((r) => r.nume !== "Necunoscut");
  return {
    total: out.length,
    copii: trim(out, limit),
  };
}

async function toolGetChildrenByWorkshopType(
  admin: SupabaseClient,
  args: { workshop_type: string; limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const target = workshopCategory(args.workshop_type);
  // Find matching active series
  const { data: series } = await admin
    .from("workshop_series")
    .select("id, title, workshop_type")
    .eq("is_active", true);
  const matchingSeries =
    ((series ?? []) as Array<{ id: string; title: string | null; workshop_type: string | null }>)
      .filter((s) => workshopCategory(s.workshop_type) === target);
  if (matchingSeries.length === 0) {
    return { categorie: target, total: 0, copii: [] };
  }
  const seriesIds = matchingSeries.map((s) => s.id);
  const { data: enrollments } = await admin
    .from("workshop_enrollments")
    .select("child_id")
    .in("series_id", seriesIds)
    .eq("is_active", true);
  const childIds = Array.from(
    new Set(
      ((enrollments ?? []) as Array<{ child_id: string }>).map((r) => r.child_id),
    ),
  );
  const names = await fetchChildNames(admin, childIds);
  const out = childIds
    .map((id) => names.get(id) ?? "")
    .filter((n) => n.length > 0)
    .sort();
  return {
    categorie: target,
    serii: matchingSeries.map((s) => s.title).filter((s): s is string => !!s),
    total: out.length,
    copii: trim(out, limit),
  };
}

async function toolGetNewChildrenThisMonth(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const { start, end } = monthBounds(new Date());
  const { data } = await admin
    .from("children")
    .select("first_name, last_name, created_at")
    .gte("created_at", start)
    .lte("created_at", `${end}T23:59:59`)
    .order("created_at", { ascending: false });
  const rows = (data ?? []) as Array<{
    first_name: string | null;
    last_name: string | null;
    created_at: string | null;
  }>;
  return {
    interval: { de_la: start, pana_la: end },
    total: rows.length,
    copii: trim(
      rows.map((r) => ({
        nume: fullName(r.first_name, r.last_name),
        inscris_la: r.created_at?.slice(0, 10) ?? null,
      })),
      limit,
    ),
  };
}

async function toolGetInactiveChildren(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const { data } = await admin
    .from("children")
    .select("first_name, last_name")
    .eq("is_active", false)
    .order("last_name");
  const rows = (data ?? []) as Array<
    { first_name: string | null; last_name: string | null }
  >;
  return {
    total: rows.length,
    copii: trim(
      rows.map((r) => fullName(r.first_name, r.last_name)).filter((s) => s),
      limit,
    ),
  };
}

async function toolGetChildrenBirthdaysUpcoming(
  admin: SupabaseClient,
  args: { days?: number; limit?: number },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 30, 1), 90);
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const { data } = await admin
    .from("children")
    .select("first_name, last_name, birth_date")
    .eq("is_active", true)
    .not("birth_date", "is", null);
  const rows = (data ?? []) as Array<
    { first_name: string | null; last_name: string | null; birth_date: string | null }
  >;
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  type Out = { nume: string; data_aniversarii: string; in_zile: number };
  const out: Out[] = [];
  for (const r of rows) {
    if (!r.birth_date) continue;
    const b = new Date(r.birth_date);
    const next = new Date(today.getFullYear(), b.getMonth(), b.getDate());
    if (next < today) next.setFullYear(today.getFullYear() + 1);
    const diff = Math.floor(
      (next.getTime() - today.getTime()) / (1000 * 60 * 60 * 24),
    );
    if (diff >= 0 && diff <= days) {
      out.push({
        nume: fullName(r.first_name, r.last_name),
        data_aniversarii: roDate(next),
        in_zile: diff,
      });
    }
  }
  out.sort((a, b) => a.in_zile - b.in_zile);
  return {
    fereastra_zile: days,
    total: out.length,
    aniversari: trim(out, limit),
  };
}

// ── Attendance ──────────────────────────────────────────────────────────────

async function toolGetAttendanceByDate(
  admin: SupabaseClient,
  args: { date: string },
): Promise<Record<string, unknown>> {
  const date = (args.date ?? "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return { eroare: "Format invalid. Folosește YYYY-MM-DD." };
  }
  const { data } = await admin
    .from("attendance")
    .select(
      "status, scheduled_workshops!scheduled_workshop_id(title, workshop_date)",
    )
    .eq("is_archived", false)
    .gte("marked_at", `${date}T00:00:00`)
    .lte("marked_at", `${date}T23:59:59`);
  const rows = (data ?? []) as Array<{
    status: string | null;
    scheduled_workshops: { title: string | null; workshop_date: string | null } | null;
  }>;
  const present = rows.filter((r) => r.status === "present").length;
  const absent = rows.filter((r) => r.status === "absent").length;
  const motivated = rows.filter((r) => r.status === "motivated").length;
  return {
    data: date,
    total_inregistrari: rows.length,
    prezente: present,
    absente: absent,
    motivate: motivated,
    rata_prezenta_procent: attendanceRate(present, present + absent + motivated),
  };
}

async function toolGetAttendanceByWorkshop(
  admin: SupabaseClient,
  args: { workshop_title: string; days?: number },
): Promise<Record<string, unknown>> {
  const title = (args.workshop_title ?? "").trim();
  if (title.length < 2) return { eroare: "Titlul atelierului este prea scurt." };
  const days = Math.min(Math.max(args.days ?? 90, 7), 365);
  const since = ymd(addDays(new Date(), -days));
  const { data } = await admin
    .from("attendance")
    .select("status, scheduled_workshops!scheduled_workshop_id(title)")
    .eq("is_archived", false)
    .gte("marked_at", since);
  const rows = (data ?? []) as Array<{
    status: string | null;
    scheduled_workshops: { title: string | null } | null;
  }>;
  const target = normalise(title);
  const filtered = rows.filter((r) =>
    normalise(r.scheduled_workshops?.title ?? "").includes(target)
  );
  const present = filtered.filter((r) => r.status === "present").length;
  const absent = filtered.filter((r) => r.status === "absent").length;
  const motivated = filtered.filter((r) => r.status === "motivated").length;
  return {
    atelier: title,
    fereastra_zile: days,
    total_inregistrari: filtered.length,
    prezente: present,
    absente: absent,
    motivate: motivated,
    rata_prezenta_procent: attendanceRate(present, present + absent + motivated),
  };
}

async function toolGetAttendanceByTrainer(
  admin: SupabaseClient,
  args: { trainer_name: string; days?: number },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 90, 7), 365);
  const trainer = await findTrainerByName(admin, args.trainer_name ?? "");
  if (!trainer) return { eroare: `Nu am găsit trainerul "${args.trainer_name}".` };
  const since = ymd(addDays(new Date(), -days));
  const { data } = await admin
    .from("attendance")
    .select(
      "status, scheduled_workshops!scheduled_workshop_id(trainer_id)",
    )
    .eq("is_archived", false)
    .gte("marked_at", since);
  const rows = (data ?? []) as Array<{
    status: string | null;
    scheduled_workshops: { trainer_id: string | null } | null;
  }>;
  const filtered = rows.filter((r) =>
    r.scheduled_workshops?.trainer_id === trainer.id
  );
  const present = filtered.filter((r) => r.status === "present").length;
  const absent = filtered.filter((r) => r.status === "absent").length;
  const motivated = filtered.filter((r) => r.status === "motivated").length;
  return {
    trainer: trainer.full,
    fereastra_zile: days,
    total_inregistrari: filtered.length,
    prezente: present,
    absente: absent,
    motivate: motivated,
    rata_prezenta_procent: attendanceRate(present, present + absent + motivated),
  };
}

async function toolGetChildrenWithConsecutiveAbsences(
  admin: SupabaseClient,
  args: { min_run?: number; limit?: number },
): Promise<Record<string, unknown>> {
  const minRun = Math.min(Math.max(args.min_run ?? 2, 2), 10);
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const since = ymd(addDays(new Date(), -90));
  const { data } = await admin
    .from("attendance")
    .select(
      "child_id, status, scheduled_workshops!scheduled_workshop_id(workshop_date)",
    )
    .eq("is_archived", false)
    .gte("marked_at", since);
  const rows = (data ?? []) as Array<{
    child_id: string;
    status: string | null;
    scheduled_workshops: { workshop_date: string | null } | null;
  }>;
  // Group by child, sort ascending, compute longest tail of consecutive absences.
  const byChild = new Map<string, Array<{ date: string; status: string | null }>>();
  for (const r of rows) {
    const d = r.scheduled_workshops?.workshop_date;
    if (!d) continue;
    if (!byChild.has(r.child_id)) byChild.set(r.child_id, []);
    byChild.get(r.child_id)!.push({ date: d, status: r.status });
  }
  type Out = { id: string; nume: string; absente_consecutive: number; ultimul_absent_la: string };
  const out: Out[] = [];
  for (const [id, list] of byChild) {
    list.sort((a, b) => a.date.localeCompare(b.date));
    let run = 0;
    let lastAbsent = "";
    for (let i = list.length - 1; i >= 0; i--) {
      if (list[i].status === "absent") {
        run += 1;
        if (!lastAbsent) lastAbsent = list[i].date;
      } else {
        break;
      }
    }
    if (run >= minRun) {
      out.push({ id, nume: "", absente_consecutive: run, ultimul_absent_la: lastAbsent });
    }
  }
  const names = await fetchChildNames(admin, out.map((r) => r.id));
  for (const r of out) r.nume = names.get(r.id) ?? "Necunoscut";
  out.sort((a, b) => b.absente_consecutive - a.absente_consecutive);
  return {
    minim_absente_consecutive: minRun,
    total: out.length,
    copii: trim(
      out.map(({ id: _id, ...rest }) => rest),
      limit,
    ),
  };
}

async function toolGetMotivatedAbsences(
  admin: SupabaseClient,
  args: { days?: number; limit?: number },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 90, 7), 365);
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const since = ymd(addDays(new Date(), -days));
  const { data } = await admin
    .from("attendance")
    .select("child_id, observation, marked_at")
    .eq("status", "motivated")
    .eq("is_archived", false)
    .gte("marked_at", since)
    .order("marked_at", { ascending: false });
  const rows = (data ?? []) as Array<{
    child_id: string;
    observation: string | null;
    marked_at: string | null;
  }>;
  const names = await fetchChildNames(admin, rows.map((r) => r.child_id));
  const perChild = new Map<string, number>();
  for (const r of rows) perChild.set(r.child_id, (perChild.get(r.child_id) ?? 0) + 1);
  const topPerChild = Array.from(perChild.entries())
    .map(([id, n]) => ({ nume: names.get(id) ?? "Necunoscut", numar: n }))
    .sort((a, b) => b.numar - a.numar);
  return {
    fereastra_zile: days,
    total_motivate: rows.length,
    top_copii: trim(topPerChild, 10),
    inregistrari_recente: trim(
      rows.map((r) => ({
        nume: names.get(r.child_id) ?? "Necunoscut",
        data: r.marked_at?.slice(0, 10) ?? null,
        observatie: r.observation && r.observation.trim().length > 0
          ? r.observation
          : null,
      })),
      limit,
    ),
  };
}

async function toolCompareAttendancePeriods(
  admin: SupabaseClient,
  args: { window_days?: number },
): Promise<Record<string, unknown>> {
  const w = Math.min(Math.max(args.window_days ?? 30, 7), 180);
  const now = new Date();
  const recentStart = ymd(addDays(now, -w));
  const recentEnd = ymd(now);
  const priorStart = ymd(addDays(now, -2 * w));
  const priorEnd = ymd(addDays(now, -w - 1));

  async function windowStats(from: string, to: string) {
    const { data } = await admin
      .from("attendance")
      .select("status")
      .eq("is_archived", false)
      .gte("marked_at", `${from}T00:00:00`)
      .lte("marked_at", `${to}T23:59:59`);
    const rows = (data ?? []) as Array<{ status: string | null }>;
    const present = rows.filter((r) => r.status === "present").length;
    const absent = rows.filter((r) => r.status === "absent").length;
    const motivated = rows.filter((r) => r.status === "motivated").length;
    const total = present + absent + motivated;
    return {
      interval: { de_la: from, pana_la: to },
      total_inregistrari: total,
      prezente: present,
      absente: absent,
      motivate: motivated,
      rata_prezenta_procent: attendanceRate(present, total),
    };
  }

  const [recent, prior] = await Promise.all([
    windowStats(recentStart, recentEnd),
    windowStats(priorStart, priorEnd),
  ]);
  const recentRate = recent.rata_prezenta_procent;
  const priorRate = prior.rata_prezenta_procent;
  const delta = recentRate !== null && priorRate !== null
    ? recentRate - priorRate
    : null;
  return {
    fereastra_zile: w,
    perioada_recenta: recent,
    perioada_anterioara: prior,
    diferenta_procentuala: delta,
    trend: delta === null
      ? "necunoscut"
      : delta > 2
      ? "în creștere"
      : delta < -2
      ? "în scădere"
      : "stabil",
  };
}

// ── Workshops ──────────────────────────────────────────────────────────────

async function toolGetWorkshopsByType(
  admin: SupabaseClient,
  args: { workshop_type: string },
): Promise<Record<string, unknown>> {
  const cat = workshopCategory(args.workshop_type ?? "");
  const { data } = await admin
    .from("workshop_series")
    .select(
      "title, workshop_type, day_of_week, start_time, end_time, " +
        "trainer_id, is_active, profiles!trainer_id(first_name, last_name)",
    )
    .eq("is_active", true);
  const rows = (data ?? []) as Array<{
    title: string | null;
    workshop_type: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
    trainer_id: string | null;
    profiles: { first_name: string | null; last_name: string | null } | null;
  }>;
  const matching = rows.filter((r) =>
    workshopCategory(r.workshop_type) === cat
  );
  return {
    categorie: cat,
    total: matching.length,
    serii: matching.map((r) => ({
      titlu: r.title,
      zi: r.day_of_week,
      interval: `${trimHm(r.start_time)} – ${trimHm(r.end_time)}`,
      trainer: r.profiles
        ? fullName(r.profiles.first_name, r.profiles.last_name)
        : null,
    })),
  };
}

async function toolGetWorkshopsByTrainer(
  admin: SupabaseClient,
  args: { trainer_name: string },
): Promise<Record<string, unknown>> {
  const t = await findTrainerByName(admin, args.trainer_name ?? "");
  if (!t) return { eroare: `Nu am găsit trainerul "${args.trainer_name}".` };
  const { data } = await admin
    .from("workshop_series")
    .select("title, workshop_type, day_of_week, start_time, end_time, is_active")
    .eq("trainer_id", t.id)
    .eq("is_active", true);
  const rows = (data ?? []) as Array<{
    title: string | null;
    workshop_type: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
  }>;
  return {
    trainer: t.full,
    total: rows.length,
    serii: rows.map((r) => ({
      titlu: r.title,
      categoria: workshopCategory(r.workshop_type),
      zi: r.day_of_week,
      interval: `${trimHm(r.start_time)} – ${trimHm(r.end_time)}`,
    })),
  };
}

async function toolGetActiveWorkshopSeries(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 30, 1), 100);
  const { data } = await admin
    .from("workshop_series")
    .select(
      "title, workshop_type, day_of_week, start_time, end_time, " +
        "profiles!trainer_id(first_name, last_name)",
    )
    .eq("is_active", true)
    .order("title");
  const rows = (data ?? []) as Array<{
    title: string | null;
    workshop_type: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
    profiles: { first_name: string | null; last_name: string | null } | null;
  }>;
  return {
    total: rows.length,
    serii: trim(
      rows.map((r) => ({
        titlu: r.title,
        categoria: workshopCategory(r.workshop_type),
        zi: r.day_of_week,
        interval: `${trimHm(r.start_time)} – ${trimHm(r.end_time)}`,
        trainer: r.profiles
          ? fullName(r.profiles.first_name, r.profiles.last_name)
          : null,
      })),
      limit,
    ),
  };
}

async function toolGetWorkshopChildren(
  admin: SupabaseClient,
  args: { workshop_title: string },
): Promise<Record<string, unknown>> {
  const title = (args.workshop_title ?? "").trim();
  if (title.length < 2) return { eroare: "Titlul atelierului este prea scurt." };
  const escaped = escapeIlike(title);
  const { data: series } = await admin
    .from("workshop_series")
    .select("id, title")
    .ilike("title", `%${escaped}%`)
    .eq("is_active", true)
    .limit(5);
  const seriesRows = (series ?? []) as Array<
    { id: string; title: string | null }
  >;
  if (seriesRows.length === 0) {
    return { atelier: title, total: 0, copii: [] };
  }
  const seriesIds = seriesRows.map((s) => s.id);
  const { data: enrollments } = await admin
    .from("workshop_enrollments")
    .select("child_id, series_id")
    .in("series_id", seriesIds)
    .eq("is_active", true);
  const enrolls = (enrollments ?? []) as Array<
    { child_id: string; series_id: string }
  >;
  const childIds = Array.from(new Set(enrolls.map((e) => e.child_id)));
  const names = await fetchChildNames(admin, childIds);
  return {
    atelier: title,
    serii_potrivite: seriesRows.map((s) => s.title).filter((s): s is string => !!s),
    total: childIds.length,
    copii: childIds
      .map((id) => names.get(id) ?? "")
      .filter((n) => n.length > 0)
      .sort(),
  };
}

async function toolGetMostPopularWorkshops(
  admin: SupabaseClient,
  args: { limit?: number; least?: boolean },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 10, 1), 30);
  const [enrollRes, seriesRes] = await Promise.all([
    admin
      .from("workshop_enrollments")
      .select("series_id")
      .eq("is_active", true),
    admin
      .from("workshop_series")
      .select("id, title, workshop_type")
      .eq("is_active", true),
  ]);
  const counts = new Map<string, number>();
  for (
    const r of (enrollRes.data ?? []) as Array<{ series_id: string | null }>
  ) {
    if (!r.series_id) continue;
    counts.set(r.series_id, (counts.get(r.series_id) ?? 0) + 1);
  }
  const series = (seriesRes.data ?? []) as Array<
    { id: string; title: string | null; workshop_type: string | null }
  >;
  const ranked = series.map((s) => ({
    titlu: s.title ?? "—",
    categoria: workshopCategory(s.workshop_type),
    copii_inscrisi: counts.get(s.id) ?? 0,
  }));
  ranked.sort((a, b) =>
    args.least
      ? a.copii_inscrisi - b.copii_inscrisi || a.titlu.localeCompare(b.titlu)
      : b.copii_inscrisi - a.copii_inscrisi || a.titlu.localeCompare(b.titlu)
  );
  return {
    criteriu: args.least ? "cele mai puțin populare" : "cele mai populare",
    total_serii: ranked.length,
    top: trim(ranked, limit),
  };
}

async function toolGetWorkshopsWithoutChildren(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const [seriesRes, enrollRes] = await Promise.all([
    admin
      .from("workshop_series")
      .select("id, title, workshop_type, day_of_week, start_time, end_time")
      .eq("is_active", true),
    admin
      .from("workshop_enrollments")
      .select("series_id")
      .eq("is_active", true),
  ]);
  const enrolled = new Set(
    ((enrollRes.data ?? []) as Array<{ series_id: string | null }>)
      .map((r) => r.series_id)
      .filter((s): s is string => !!s),
  );
  const series = (seriesRes.data ?? []) as Array<{
    id: string;
    title: string | null;
    workshop_type: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
  }>;
  const empty = series.filter((s) => !enrolled.has(s.id));
  return {
    total: empty.length,
    serii: empty.map((s) => ({
      titlu: s.title,
      categoria: workshopCategory(s.workshop_type),
      zi: s.day_of_week,
      interval: `${trimHm(s.start_time)} – ${trimHm(s.end_time)}`,
    })),
  };
}

async function toolGetWorkshopsWithoutTrainer(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const today = ymd(new Date());
  const [scheduledRes, seriesRes] = await Promise.all([
    admin
      .from("scheduled_workshops")
      .select("title, workshop_date, start_time, end_time")
      .is("trainer_id", null)
      .gte("workshop_date", today)
      .eq("is_active", true)
      .order("workshop_date"),
    admin
      .from("workshop_series")
      .select("title, workshop_type, day_of_week, start_time, end_time")
      .is("trainer_id", null)
      .eq("is_active", true),
  ]);
  const scheduled = (scheduledRes.data ?? []) as Array<{
    title: string | null;
    workshop_date: string | null;
    start_time: string | null;
    end_time: string | null;
  }>;
  const series = (seriesRes.data ?? []) as Array<{
    title: string | null;
    workshop_type: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
  }>;
  return {
    sesiuni_viitoare_fara_trainer: scheduled.map((r) => ({
      titlu: r.title,
      data: r.workshop_date,
      interval: `${trimHm(r.start_time)} – ${trimHm(r.end_time)}`,
    })),
    serii_active_fara_trainer: series.map((s) => ({
      titlu: s.title,
      categoria: workshopCategory(s.workshop_type),
      zi: s.day_of_week,
      interval: `${trimHm(s.start_time)} – ${trimHm(s.end_time)}`,
    })),
  };
}

async function toolGetWorkshopCapacitySummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const [seriesRes, enrollRes] = await Promise.all([
    admin
      .from("workshop_series")
      .select("id, title")
      .eq("is_active", true),
    admin
      .from("workshop_enrollments")
      .select("series_id")
      .eq("is_active", true),
  ]);
  const counts = new Map<string, number>();
  for (
    const r of (enrollRes.data ?? []) as Array<{ series_id: string | null }>
  ) {
    if (r.series_id) counts.set(r.series_id, (counts.get(r.series_id) ?? 0) + 1);
  }
  const series = (seriesRes.data ?? []) as Array<
    { id: string; title: string | null }
  >;
  const capacity = 10; // From center spec: "grupe mici, maxim 10 copii"
  const rows = series.map((s) => ({
    titlu: s.title,
    copii_inscrisi: counts.get(s.id) ?? 0,
    capacitate_aproximativa: capacity,
    procent_ocupare: Math.round(((counts.get(s.id) ?? 0) / capacity) * 100),
  }));
  rows.sort((a, b) => b.procent_ocupare - a.procent_ocupare);
  return {
    capacitate_referinta: capacity,
    nota:
      "Capacitatea de 10 copii/grupă este politica centrului; nu este stocată per serie. Procentul este aproximativ.",
    serii: rows,
  };
}

// ── Trainers ────────────────────────────────────────────────────────────────

async function toolGetTrainerProfile(
  admin: SupabaseClient,
  args: { trainer_name: string },
): Promise<Record<string, unknown>> {
  const t = await findTrainerByName(admin, args.trainer_name ?? "");
  if (!t) return { eroare: `Nu am găsit trainerul "${args.trainer_name}".` };
  const [seriesRes, attRes] = await Promise.all([
    admin
      .from("workshop_series")
      .select("title, workshop_type, day_of_week, start_time, end_time")
      .eq("trainer_id", t.id)
      .eq("is_active", true),
    admin
      .from("scheduled_workshops")
      .select("id")
      .eq("trainer_id", t.id)
      .gte("workshop_date", ymd(addDays(new Date(), -30)))
      .eq("is_active", true),
  ]);
  const series = (seriesRes.data ?? []) as Array<{
    title: string | null;
    workshop_type: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
  }>;
  return {
    nume: t.full,
    serii_active: series.length,
    sesiuni_ultimele_30_zile: (attRes.data ?? []).length,
    serii: series.map((s) => ({
      titlu: s.title,
      categoria: workshopCategory(s.workshop_type),
      zi: s.day_of_week,
      interval: `${trimHm(s.start_time)} – ${trimHm(s.end_time)}`,
    })),
  };
}

async function toolGetTrainerWorkload(
  admin: SupabaseClient,
  args: { days?: number; limit?: number },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 30, 7), 180);
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const since = ymd(addDays(new Date(), -days));
  const [trainersRes, scheduledRes] = await Promise.all([
    admin.from("profiles").select("id, first_name, last_name").eq("role", "trainer"),
    admin
      .from("scheduled_workshops")
      .select("trainer_id")
      .gte("workshop_date", since)
      .eq("is_active", true),
  ]);
  const counts = new Map<string, number>();
  for (
    const r of (scheduledRes.data ?? []) as Array<{ trainer_id: string | null }>
  ) {
    if (r.trainer_id) counts.set(r.trainer_id, (counts.get(r.trainer_id) ?? 0) + 1);
  }
  const trainers = (trainersRes.data ?? []) as Array<
    { id: string; first_name: string | null; last_name: string | null }
  >;
  const rows = trainers.map((t) => ({
    nume: fullName(t.first_name, t.last_name),
    sesiuni_in_perioada: counts.get(t.id) ?? 0,
  }));
  rows.sort((a, b) => b.sesiuni_in_perioada - a.sesiuni_in_perioada);
  return {
    fereastra_zile: days,
    traineri: trim(rows, limit),
  };
}

async function toolGetTrainerWeekSchedule(
  admin: SupabaseClient,
  args: { trainer_name: string },
): Promise<Record<string, unknown>> {
  const t = await findTrainerByName(admin, args.trainer_name ?? "");
  if (!t) return { eroare: `Nu am găsit trainerul "${args.trainer_name}".` };
  const weekStart = ymd(startOfWeek(new Date()));
  const weekEnd = ymd(addDays(startOfWeek(new Date()), 6));
  const { data } = await admin
    .from("scheduled_workshops")
    .select("title, workshop_date, day_of_week, start_time, end_time")
    .eq("trainer_id", t.id)
    .eq("is_active", true)
    .gte("workshop_date", weekStart)
    .lte("workshop_date", weekEnd)
    .order("workshop_date")
    .order("start_time");
  const rows = (data ?? []) as Array<{
    title: string | null;
    workshop_date: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
  }>;
  return {
    trainer: t.full,
    interval: { de_la: weekStart, pana_la: weekEnd },
    total_sesiuni: rows.length,
    sesiuni: rows.map((r) => ({
      data: r.workshop_date,
      zi: r.day_of_week,
      titlu: r.title,
      interval: `${trimHm(r.start_time)} – ${trimHm(r.end_time)}`,
    })),
  };
}

// ── Parents ─────────────────────────────────────────────────────────────────

async function toolSearchParentByNameOrEmail(
  admin: SupabaseClient,
  args: { query: string; limit?: number },
): Promise<Record<string, unknown>> {
  const q = (args.query ?? "").trim();
  if (q.length < 2) return { results: [], nota: "Interogare prea scurtă." };
  const limit = Math.min(Math.max(args.limit ?? 10, 1), 30);
  const escaped = escapeIlike(q);
  // Search profiles
  const { data: profiles } = await admin
    .from("profiles")
    .select("id, first_name, last_name")
    .eq("role", "parent")
    .or(`first_name.ilike.%${escaped}%,last_name.ilike.%${escaped}%`)
    .limit(limit);
  const profileRows = (profiles ?? []) as Array<
    { id: string; first_name: string | null; last_name: string | null }
  >;
  // Search by email via parent_setup_tokens
  let byEmail: Array<{ id: string; full: string }> = [];
  if (q.includes("@") || q.length >= 3) {
    const { data: tokens } = await admin
      .from("parent_setup_tokens")
      .select("parent_id, email")
      .ilike("email", `%${escaped}%`)
      .limit(limit);
    const tokenRows = (tokens ?? []) as Array<
      { parent_id: string; email: string | null }
    >;
    const ids = tokenRows.map((t) => t.parent_id);
    if (ids.length > 0) {
      const names = await fetchTrainerNames(admin, ids); // reuse profile-name helper
      byEmail = ids.map((id) => ({ id, full: names.get(id) ?? "Necunoscut" }));
    }
  }
  const seen = new Set<string>();
  const merged: Array<{ nume: string }> = [];
  for (const p of profileRows) {
    if (seen.has(p.id)) continue;
    seen.add(p.id);
    merged.push({ nume: fullName(p.first_name, p.last_name) });
  }
  for (const e of byEmail) {
    if (seen.has(e.id)) continue;
    seen.add(e.id);
    merged.push({ nume: e.full });
  }
  return {
    interogare: q,
    total: merged.length,
    rezultate: trim(merged, limit),
    nota: "Adresele de email nu sunt expuse aici; folosește get_pending_parent_setups pentru emailuri din invitații.",
  };
}

async function toolGetParentChildren(
  admin: SupabaseClient,
  args: { parent_name: string },
): Promise<Record<string, unknown>> {
  const q = (args.parent_name ?? "").trim();
  if (q.length < 2) return { eroare: "Numele este prea scurt." };
  const escaped = escapeIlike(q);
  const { data: parents } = await admin
    .from("profiles")
    .select("id, first_name, last_name")
    .eq("role", "parent")
    .or(`first_name.ilike.%${escaped}%,last_name.ilike.%${escaped}%`)
    .limit(5);
  const parentRows = (parents ?? []) as Array<
    { id: string; first_name: string | null; last_name: string | null }
  >;
  if (parentRows.length === 0) {
    return { eroare: `Nu am găsit un părinte după "${q}".` };
  }
  const target = normalise(q);
  const exact = parentRows.find((r) =>
    normalise(fullName(r.first_name, r.last_name)) === target
  );
  const picked = exact ?? parentRows[0];
  const { data: links } = await admin
    .from("child_parents")
    .select("child_id, is_primary, relationship")
    .eq("parent_id", picked.id);
  const linkRows = (links ?? []) as Array<{
    child_id: string;
    is_primary: boolean | null;
    relationship: string | null;
  }>;
  const names = await fetchChildNames(admin, linkRows.map((l) => l.child_id));
  return {
    parinte: fullName(picked.first_name, picked.last_name),
    total_copii: linkRows.length,
    copii: linkRows.map((l) => ({
      nume: names.get(l.child_id) ?? "Necunoscut",
      contact_principal: l.is_primary === true,
      relatie: l.relationship,
    })),
  };
}

async function toolGetPendingParentSetups(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const nowIso = new Date().toISOString();
  const { data } = await admin
    .from("parent_setup_tokens")
    .select("parent_id, email, created_at, expires_at, attempt_count")
    .is("consumed_at", null)
    .gte("expires_at", nowIso)
    .order("created_at", { ascending: false });
  const rows = (data ?? []) as Array<{
    parent_id: string;
    email: string | null;
    created_at: string | null;
    expires_at: string | null;
    attempt_count: number | null;
  }>;
  const names = await fetchTrainerNames(admin, rows.map((r) => r.parent_id));
  return {
    total: rows.length,
    invitatii_active: trim(
      rows.map((r) => ({
        nume: names.get(r.parent_id) ?? "Necunoscut",
        email: r.email,
        trimisa_la: r.created_at?.slice(0, 10) ?? null,
        expira_la: r.expires_at?.slice(0, 10) ?? null,
        incercari_esuate: r.attempt_count ?? 0,
      })),
      limit,
    ),
  };
}

async function toolGetExpiredParentSetups(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const nowIso = new Date().toISOString();
  const { data } = await admin
    .from("parent_setup_tokens")
    .select("parent_id, email, created_at, expires_at")
    .is("consumed_at", null)
    .lt("expires_at", nowIso)
    .order("expires_at", { ascending: false });
  const rows = (data ?? []) as Array<{
    parent_id: string;
    email: string | null;
    created_at: string | null;
    expires_at: string | null;
  }>;
  // Drop entries where the parent eventually consumed another token (already activated).
  const ids = rows.map((r) => r.parent_id);
  let activated = new Set<string>();
  if (ids.length > 0) {
    const { data: consumed } = await admin
      .from("parent_setup_tokens")
      .select("parent_id")
      .in("parent_id", ids)
      .not("consumed_at", "is", null);
    activated = new Set(
      ((consumed ?? []) as Array<{ parent_id: string }>).map((r) => r.parent_id),
    );
  }
  const still = rows.filter((r) => !activated.has(r.parent_id));
  const names = await fetchTrainerNames(admin, still.map((r) => r.parent_id));
  return {
    total: still.length,
    invitatii_expirate: trim(
      still.map((r) => ({
        nume: names.get(r.parent_id) ?? "Necunoscut",
        email: r.email,
        trimisa_la: r.created_at?.slice(0, 10) ?? null,
        expirata_la: r.expires_at?.slice(0, 10) ?? null,
      })),
      limit,
    ),
    recomandare:
      "Folosește acțiunea de reinvitare din Child Details pentru a retrimite invitația.",
  };
}

// ── Payments ────────────────────────────────────────────────────────────────
//
// The old toolGetPaymentMethodSummary was removed on 2026-07-09 — the
// same aggregate data (per-method counts) is now returned inside
// toolGetPaymentsByMethod under `pe_metoda.<METHOD>.total`, so we can
// present a single tool to the model and eliminate the routing
// ambiguity that made "cine a plătit cu POS" respond with counts
// instead of names.

/// Method key used internally by [toolGetPaymentsByMethod].
type MethodKey = "pos" | "op" | "unknown";

/// Raw shape read from `payment_cycles`. Children and confirmer profiles
/// are joined in code via batched follow-up queries — we intentionally
/// do NOT use PostgREST's `children!inner(...)` embedding because in
/// some environments the FK is not auto-detected (or the schema cache
/// is stale), causing the embed to silently return null. That was the
/// bug the previous iteration hit: `!inner` dropped rows AND the model
/// then reported "child names not available". The explicit
/// batched-join approach here is bulletproof regardless of whether
/// PostgREST introspection is healthy.
interface PaymentCycleRow {
  id: string;
  child_id: string;
  status: string | null;
  payment_method: string | null;
  paid_at: string | null;
  created_at: string | null;
  confirmed_by: string | null;
  amount?: number | null;
  currency?: string | null;
  period_start: string | null;
  period_end: string | null;
  sessions_count: number | null;
  notes: string | null;
}

/// Lists confirmed payments grouped by method (POS / OP / null).
///
/// Query flow (three batched round-trips, no PostgREST embed):
///   1. Fetch payment_cycles rows filtered by status + paid_at window +
///      payment_method (one query per method group so per-method limit
///      is enforced independently; queries run in parallel).
///   2. Collect distinct child_id values → fetch children by id (single
///      SELECT). Filter out `payment_type = 'free'` in memory.
///   3. Collect distinct confirmed_by ids → fetch profiles by id
///      (single SELECT).
///
/// Every output row is FLAT: no nested `children` object. Fields:
///   • payment_cycle_id, child_id, child_first_name, child_last_name,
///     copil (full name), parinte (children.parent_name)
///   • status ('paid' | 'paid_advance'), metoda (upper-cased or null)
///   • suma + moneda when amount is available; else null + top-level
///     nota that the caller must transcribe verbatim
///   • confirmed_at (paid_at, YYYY-MM-DD), created_at, confirmed_by
///     (raw id preserved for auditing), confirmat_de (confirmer full
///     name from the batched profiles fetch)
///   • perioada (period_start – period_end), sedinte, ciclu_note
///
/// When a child_id can't be resolved to a name (child row missing or
/// hidden by RLS), `copil` becomes the debug string
/// "child_id: <uuid> (nume nerezolvat)" so the model has a stable
/// non-null anchor. Same idea for confirmer.
///
/// The `debug` block at the top of the response reports counts of
/// (a) cycles fetched, (b) children fetched, (c) confirmers fetched,
/// (d) rows dropped because payment_type=='free'. Lets us diagnose
/// mismatches without shipping a second-tool round trip.
///
/// Aliases normalised at the entry point: card→pos, transfer/transfer
/// bancar/bank transfer/ordin de plată→op, unknown/necunoscut/null→
/// unknown. Mirrors the system-prompt glossary.
async function toolGetPaymentsByMethod(
  admin: SupabaseClient,
  args: {
    methods?: string[];
    method?: string;
    year?: number;
    month?: number;
    days?: number;
    limit_per_method?: number;
  },
): Promise<Record<string, unknown>> {
  const methodMap: Record<string, MethodKey> = {
    "pos": "pos",
    "card": "pos",
    "op": "op",
    "transfer": "op",
    "transfer bancar": "op",
    "bank transfer": "op",
    "ordin de plata": "op",
    "ordin de plată": "op",
    "unknown": "unknown",
    "necunoscut": "unknown",
    "null": "unknown",
  };
  // Accept either the new `methods: string[]` or the legacy scalar
  // `method: string` (older callers). Legacy scalar defaults to "pos".
  const rawMethods = Array.isArray(args.methods) && args.methods.length > 0
    ? args.methods
    : (args.method ? [args.method] : ["pos"]);
  const methods: MethodKey[] = Array.from(
    new Set(
      rawMethods
        .map((m) => methodMap[(m ?? "").toLowerCase().trim()])
        .filter((m): m is MethodKey => !!m),
    ),
  );
  if (methods.length === 0) methods.push("pos");

  // Time window: year+month wins over `days`.
  const limitPerMethod = Math.min(
    Math.max(args.limit_per_method ?? 100, 1),
    200,
  );
  let sinceIso: string;
  let untilIso: string | null = null;
  let windowLabel: string;
  if (args.month) {
    const now = new Date();
    const year = args.year ?? now.getUTCFullYear();
    const monthIdx = args.month - 1;
    const start = new Date(Date.UTC(year, monthIdx, 1));
    const end = new Date(Date.UTC(year, monthIdx + 1, 0));
    sinceIso = ymd(start);
    untilIso = ymd(end);
    windowLabel = `${sinceIso} – ${untilIso}`;
  } else {
    const days = Math.min(Math.max(args.days ?? 30, 1), 365);
    sinceIso = ymd(addDays(new Date(), -days));
    windowLabel = `ultimele ${days} zile (de la ${sinceIso})`;
  }

  // ── Query 1: payment_cycles (one per method, parallel) ────────────
  //
  // No `children!inner(...)` embed. Free-participant filtering is
  // deferred to the in-memory merge step so the query is not gated on
  // PostgREST's FK auto-detection.
  //
  // Note (2026-08-14): amount + currency columns are NOT selected here.
  // The application does not store per-cycle amounts (every row has
  // amount IS NULL) and exposing them to the model led to hallucinated
  // sums ("300 RON") in production. The operator asked to strip every
  // monetary field from POS/OP responses. Reports are done outside the
  // app.
  const selectCols =
    "id, child_id, status, payment_method, paid_at, created_at, " +
    "confirmed_by, period_start, period_end, sessions_count, notes";

  const perMethodQueries = methods.map((m) => {
    let q = admin
      .from("payment_cycles")
      .select(selectCols)
      .in("status", ["paid", "paid_advance"])
      .gte("paid_at", sinceIso)
      .order("paid_at", { ascending: false })
      .limit(limitPerMethod);
    if (untilIso) q = q.lte("paid_at", untilIso);
    if (m === "unknown") {
      q = q.is("payment_method", null);
    } else {
      q = q.eq("payment_method", m);
    }
    return q;
  });
  const perMethodResults = await Promise.all(perMethodQueries);

  // ── Query 2: children (single batched fetch) ──────────────────────
  const allChildIds = new Set<string>();
  for (const res of perMethodResults) {
    const rows = (res.data ?? []) as PaymentCycleRow[];
    for (const r of rows) {
      if (r.child_id) allChildIds.add(r.child_id);
    }
  }
  const childMap = new Map<
    string,
    {
      first_name: string | null;
      last_name: string | null;
      parent_name: string | null;
      payment_type: string | null;
    }
  >();
  let childrenFetched = 0;
  if (allChildIds.size > 0) {
    const { data: kids, error: kidsErr } = await admin
      .from("children")
      .select("id, first_name, last_name, parent_name, payment_type")
      .in("id", Array.from(allChildIds));
    if (!kidsErr) {
      for (
        const c of (kids ?? []) as Array<{
          id: string;
          first_name: string | null;
          last_name: string | null;
          parent_name: string | null;
          payment_type: string | null;
        }>
      ) {
        childMap.set(c.id, {
          first_name: c.first_name,
          last_name: c.last_name,
          parent_name: c.parent_name,
          payment_type: c.payment_type,
        });
      }
      childrenFetched = kids?.length ?? 0;
    }
  }

  // ── Query 3: confirmer profiles (single batched fetch) ────────────
  const allConfirmerIds = new Set<string>();
  for (const res of perMethodResults) {
    const rows = (res.data ?? []) as PaymentCycleRow[];
    for (const r of rows) {
      if (r.confirmed_by) allConfirmerIds.add(r.confirmed_by);
    }
  }
  const confirmerNames = new Map<string, string>();
  let confirmersFetched = 0;
  if (allConfirmerIds.size > 0) {
    const { data: profs } = await admin
      .from("profiles")
      .select("id, first_name, last_name")
      .in("id", Array.from(allConfirmerIds));
    for (
      const p of (profs ?? []) as Array<{
        id: string;
        first_name: string | null;
        last_name: string | null;
      }>
    ) {
      confirmerNames.set(p.id, fullName(p.first_name, p.last_name));
    }
    confirmersFetched = profs?.length ?? 0;
  }

  // ── Merge + flatten ──────────────────────────────────────────────
  //
  // Deliberately does NOT include suma / moneda. Amounts are absent
  // from the schema in practice (every payment_cycles row has amount
  // IS NULL) and exposing them tempted the model to hallucinate
  // values like "300 RON". Reports needing monetary figures are done
  // outside the app.
  const mapRow = (r: PaymentCycleRow) => {
    const child = childMap.get(r.child_id) ?? null;
    // Fallback name string ensures every row has a non-null `copil`
    // anchor even when RLS or a missing row hides the child.
    const copil = child
      ? fullName(child.first_name, child.last_name)
      : `child_id: ${r.child_id} (nume nerezolvat)`;
    const confirmatDe = r.confirmed_by
      ? (confirmerNames.get(r.confirmed_by) ??
        `confirmed_by: ${r.confirmed_by} (nume nerezolvat)`)
      : null;
    return {
      payment_cycle_id: r.id,
      child_id: r.child_id,
      child_first_name: child?.first_name ?? null,
      child_last_name: child?.last_name ?? null,
      copil,
      parinte: child?.parent_name ?? null,
      status: r.status,
      metoda: (r.payment_method ?? "").toUpperCase() || null,
      confirmed_at: r.paid_at?.slice(0, 10) ?? null,
      created_at: r.created_at?.slice(0, 10) ?? null,
      confirmed_by: r.confirmed_by,
      confirmat_de: confirmatDe,
      perioada: r.period_start && r.period_end
        ? `${r.period_start} – ${r.period_end}`
        : null,
      sedinte: r.sessions_count,
      ciclu_note: (r.notes ?? "").trim() || null,
    };
  };

  // ── Grouped assembly ──────────────────────────────────────────────
  const groups: Record<string, {
    total: number;
    plati: ReturnType<typeof mapRow>[];
  }> = {};
  let anyErr: string | null = null;
  let grandTotal = 0;
  let cyclesFetched = 0;
  let droppedFree = 0;
  for (let i = 0; i < methods.length; i++) {
    const method = methods[i];
    const res = perMethodResults[i];
    const key = method === "unknown" ? "NECUNOSCUT" : method.toUpperCase();
    if (res.error) {
      anyErr = res.error.message;
      groups[key] = { total: 0, plati: [] };
      continue;
    }
    const rows = (res.data ?? []) as PaymentCycleRow[];
    cyclesFetched += rows.length;
    const filtered = rows.filter((r) => {
      const child = childMap.get(r.child_id);
      if (child && child.payment_type === "free") {
        droppedFree++;
        return false;
      }
      return true;
    });
    const plati = filtered.map(mapRow);
    grandTotal += plati.length;
    groups[key] = {
      total: plati.length,
      plati,
    };
  }

  return {
    metode_cerute: methods.map((m) =>
      m === "unknown" ? "NECUNOSCUT" : m.toUpperCase()
    ),
    fereastra: windowLabel,
    limit_per_metoda: limitPerMethod,
    total_plati: grandTotal,
    pe_metoda: groups,
    debug: {
      cycles_fetched: cyclesFetched,
      children_fetched: childrenFetched,
      confirmers_fetched: confirmersFetched,
      dropped_free_participants: droppedFree,
      unresolved_child_ids: Array.from(allChildIds).filter(
        (id) => !childMap.has(id),
      ).length,
      unresolved_confirmer_ids: Array.from(allConfirmerIds).filter(
        (id) => !confirmerNames.has(id),
      ).length,
    },
    nota: anyErr ? `Interogare parțial eșuată: ${anyErr}` : null,
  };
}

async function toolGetAdvancePaidCycles(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "child_id, paid_at, payment_method, sessions_count, series_id, " +
        "children!inner(payment_type), " +
        "workshop_series!series_id(title)",
    )
    .eq("status", "paid_advance")
    .eq("children.payment_type", "paid")
    .order("paid_at", { ascending: false });
  const rows = (data ?? []) as Array<{
    child_id: string;
    paid_at: string | null;
    payment_method: string | null;
    sessions_count: number | null;
    series_id: string | null;
    workshop_series: { title: string | null } | null;
  }>;
  const names = await fetchChildNames(admin, rows.map((r) => r.child_id));
  return {
    total: rows.length,
    cicluri_in_avans: trim(
      rows.map((r) => ({
        nume: names.get(r.child_id) ?? "Necunoscut",
        atelier: r.workshop_series?.title ?? null,
        platit_la: r.paid_at?.slice(0, 10) ?? null,
        metoda: (r.payment_method ?? "").toUpperCase() || null,
        sedinte: r.sessions_count,
      })),
      limit,
    ),
    nota:
      "Ciclurile paid_advance sunt per (copil, atelier). Un copil poate avea " +
      "un avans separat pentru fiecare atelier la care e înscris.",
  };
}

async function toolGetCancelledPaymentCycles(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "child_id, period_start, period_end, sessions_count, " +
        "children!inner(payment_type)",
    )
    .eq("status", "cancelled")
    .eq("children.payment_type", "paid")
    .order("period_start", { ascending: false });
  const rows = (data ?? []) as Array<{
    child_id: string;
    period_start: string | null;
    period_end: string | null;
    sessions_count: number | null;
  }>;
  const names = await fetchChildNames(admin, rows.map((r) => r.child_id));
  return {
    total: rows.length,
    cicluri_anulate: trim(
      rows.map((r) => ({
        nume: names.get(r.child_id) ?? "Necunoscut",
        perioada: r.period_start && r.period_end
          ? `${r.period_start} – ${r.period_end}`
          : null,
        sedinte: r.sessions_count,
      })),
      limit,
    ),
  };
}

async function toolGetPaymentCyclesByChild(
  admin: SupabaseClient,
  args: { child_name: string; limit?: number },
): Promise<Record<string, unknown>> {
  const child = await findChildByName(admin, args.child_name ?? "");
  if (!child) return { eroare: `Nu am găsit copilul "${args.child_name}".` };

  // Free participants have no payment workflow; surface that fact
  // explicitly instead of returning legacy cycle rows.
  const { data: meta } = await admin
    .from("children")
    .select("payment_type")
    .eq("id", child.id)
    .maybeSingle();
  if ((meta?.payment_type as string | undefined) === "free") {
    return {
      copil: child.full,
      tip_participare: "gratuit",
      total: 0,
      cicluri: [],
      nota:
        "Copilul are participare gratuită — nu se generează cicluri de plată " +
        "pentru el. Pentru istoricul prezenței folosește get_child_recent_activity.",
    };
  }

  const limit = Math.min(Math.max(args.limit ?? 30, 1), 60);
  // Grouped per (child, series) as of migration 20260820. Include the
  // series title so the model can group its answer per workshop.
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "period_start, period_end, sessions_count, status, payment_method, " +
        "paid_at, series_id, workshop_series!series_id(title)",
    )
    .eq("child_id", child.id)
    .order("period_start", { ascending: false })
    .limit(limit);
  const rows = (data ?? []) as Array<{
    period_start: string | null;
    period_end: string | null;
    sessions_count: number | null;
    status: string | null;
    payment_method: string | null;
    paid_at: string | null;
    series_id: string | null;
    workshop_series: { title: string | null } | null;
  }>;

  // Group by series title so the model returns per-workshop status.
  const bySeries = new Map<string, Array<Record<string, unknown>>>();
  for (const r of rows) {
    const title = r.workshop_series?.title ?? "Ciclu fără serie asociată";
    if (!bySeries.has(title)) bySeries.set(title, []);
    bySeries.get(title)!.push({
      perioada: r.period_start && r.period_end
        ? `${r.period_start} – ${r.period_end}`
        : null,
      sedinte: r.sessions_count,
      status: paymentLabel(r.status, r.payment_method),
      platit_la: r.paid_at?.slice(0, 10) ?? null,
    });
  }

  return {
    copil: child.full,
    total: rows.length,
    per_atelier: Array.from(bySeries.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([title, cycles]) => ({
        atelier: title,
        total_cicluri: cycles.length,
        cicluri: cycles,
      })),
    nota:
      "Ciclurile de plată sunt INDEPENDENTE per atelier. Când răspunzi " +
      "despre situația plăților copilului, grupează per_atelier și " +
      "prezintă statusul fiecărui atelier separat.",
  };
}

// ── Notifications ───────────────────────────────────────────────────────────

async function toolGetNotificationsSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const since = ymd(addDays(new Date(), -30));
  const todayStart = ymd(new Date());
  const [totalRes, unreadRes, todayRes, lastRes] = await Promise.all([
    admin
      .from("notifications")
      .select("id", { count: "exact", head: true })
      .gte("created_at", since),
    admin
      .from("notifications")
      .select("id", { count: "exact", head: true })
      .eq("is_read", false),
    admin
      .from("notifications")
      .select("id", { count: "exact", head: true })
      .gte("created_at", `${todayStart}T00:00:00`),
    admin
      .from("notifications")
      .select("id, title, type, priority, is_read, created_at")
      .order("created_at", { ascending: false })
      .limit(50),
  ]);
  const lastRows = (lastRes.data ?? []) as Array<{
    id: string;
    title: string | null;
    type: string | null;
    priority: string | null;
    is_read: boolean | null;
    created_at: string | null;
  }>;
  const byType = new Map<string, number>();
  const byPriority = new Map<string, number>();
  let paymentCount = 0;
  let attendanceCount = 0;
  for (const r of lastRows) {
    const t = r.type ?? "necunoscut";
    byType.set(t, (byType.get(t) ?? 0) + 1);
    const p = r.priority ?? "normal";
    byPriority.set(p, (byPriority.get(p) ?? 0) + 1);
    if (t === "payment") paymentCount += 1;
    if (t === "attendance") attendanceCount += 1;
  }
  return {
    total_ultimele_30_zile: totalRes.count ?? 0,
    necitite_total: unreadRes.count ?? 0,
    notificari_azi: todayRes.count ?? 0,
    pe_tip_ultimele_50: Array.from(byType.entries())
      .map(([tip, numar]) => ({ tip, numar }))
      .sort((a, b) => b.numar - a.numar),
    pe_prioritate_ultimele_50: Array.from(byPriority.entries())
      .map(([prioritate, numar]) => ({ prioritate, numar }))
      .sort((a, b) => b.numar - a.numar),
    notificari_plati_ultimele_50: paymentCount,
    notificari_prezenta_ultimele_50: attendanceCount,
    ultimele_10: lastRows.slice(0, 10).map((r) => ({
      titlu: r.title,
      tip: r.type,
      prioritate: r.priority,
      citita: r.is_read === true,
      data: r.created_at?.slice(0, 10) ?? null,
    })),
  };
}

async function toolGetRecentNotifications(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 10, 1), 30);
  const { data } = await admin
    .from("notifications")
    .select("title, type, is_read, created_at")
    .order("created_at", { ascending: false })
    .limit(limit);
  const rows = (data ?? []) as Array<{
    title: string | null;
    type: string | null;
    is_read: boolean | null;
    created_at: string | null;
  }>;
  return {
    total: rows.length,
    notificari: rows.map((r) => ({
      titlu: r.title,
      tip: r.type,
      citita: r.is_read === true,
      data: r.created_at?.slice(0, 10) ?? null,
    })),
  };
}

// ── Insight composites ──────────────────────────────────────────────────────

async function toolGetWeeklyActionPlan(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const [risk, fin, alerts, week, missing, progress, materials, nearCycle, amountSummary] =
    await Promise.all([
      toolGetRiskChildren(admin),
      toolGetFinancialSummary(admin),
      toolGetImportantAlerts(admin),
      toolGetWeekSummary(admin),
      toolGetChildrenMissingProfileData(admin),
      toolGetProgressSummary(admin),
      toolGetMaterialsSummary(admin),
      toolGetChildrenNearPaymentCycle(admin),
      toolGetPaymentAmountSummary(admin, {}),
    ]);
  const actions: string[] = [];
  const riskCount = (risk.total_copii_in_risc as number) ?? 0;
  if (riskCount > 0) {
    actions.push(
      `Contactează părinții pentru cei ${riskCount} copii în risc (prezență scăzută sau plăți restante).`,
    );
  }
  const overdue = (fin.cicluri_restante as number) ?? 0;
  if (overdue > 0) {
    actions.push(`Recuperează ${overdue} cicluri de plată restante înainte de finalul săptămânii.`);
  }
  const due = (fin.cicluri_neincasate as number) ?? 0;
  if (due > 0) {
    actions.push(`Confirmă încasarea celor ${due} cicluri de plată neconfirmate.`);
  }
  const nearCount = (nearCycle.total as number) ?? 0;
  if (nearCount > 0) {
    actions.push(
      `Pregătește facturarea pentru ${nearCount} copii aproape de finalul ciclului (3/4 prezențe).`,
    );
  }
  if (((alerts.detalii as Record<string, number>).ateliere_fara_trainer ?? 0) > 0) {
    actions.push(
      `Asignează trainer la ${(alerts.detalii as Record<string, number>).ateliere_fara_trainer} sesiuni viitoare fără trainer.`,
    );
  }
  if (((alerts.detalii as Record<string, number>).serii_fara_copii ?? 0) > 0) {
    actions.push(
      `Promovează sau evaluează cele ${(alerts.detalii as Record<string, number>).serii_fara_copii} serii fără copii înscriși.`,
    );
  }
  const needsReview = ((progress.pe_status as Record<string, number> | undefined)?.needs_review) ?? 0;
  if (needsReview > 0) {
    actions.push(
      `${needsReview} observații de progres marcate 'needs_review' — revizuiește-le împreună cu trainerii.`,
    );
  }
  const missingBirth = ((missing.fara_data_nasterii as { numar?: number })?.numar) ?? 0;
  if (missingBirth > 0) {
    actions.push(
      `Completează data nașterii pentru ${missingBirth} copii activi (calitatea datelor).`,
    );
  }
  return {
    saptamana: week,
    alerte: alerts,
    actiuni_recomandate: actions,
    prioritate_inalta: actions.slice(0, 3),
    progres: progress.nota
      ? { nota: progress.nota }
      : { needs_review: needsReview },
    materiale: materials.nota
      ? { nota: materials.nota }
      : { total_active: materials.total_active },
    plati_cu_suma: amountSummary.nota
      ? { nota: amountSummary.nota }
      : {
          suma_incasata: amountSummary.suma_incasata,
          suma_restanta: amountSummary.suma_restanta,
        },
  };
}

async function toolGetGrowthOpportunities(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const [popular, capacity, demos, noWorkshop, parentStatus] = await Promise.all([
    toolGetMostPopularWorkshops(admin, { limit: 5 }),
    toolGetWorkshopCapacitySummary(admin),
    toolGetDemoWorkshopsSummary(admin, { scope: "upcoming" }),
    toolGetChildrenWithoutActiveWorkshop(admin, { limit: 10 }),
    toolGetParentAccountStatus(admin),
  ]);
  const opportunities: string[] = [];
  const top = (popular.top as Array<{ titlu: string; copii_inscrisi: number }>) ?? [];
  if (top.length > 0 && top[0].copii_inscrisi >= 8) {
    opportunities.push(
      `Atelierul "${top[0].titlu}" se apropie de capacitatea maximă (${top[0].copii_inscrisi}/10) — ia în calcul o serie suplimentară.`,
    );
  }
  const underused = ((capacity.serii as Array<
    { titlu: string; procent_ocupare: number }
  >) ?? []).filter((s) => s.procent_ocupare <= 40);
  if (underused.length > 0) {
    opportunities.push(
      `${underused.length} serii sunt sub 40% ocupare — potential pentru campanie de înscrieri sau reorientare.`,
    );
  }
  const demoTotal = (demos.total as number) ?? 0;
  if (demoTotal > 0) {
    opportunities.push(
      `Există ${demoTotal} ateliere demo programate — convertirea lor în înscrieri active este o oportunitate directă.`,
    );
  }
  const unenrolledKids = (noWorkshop.total as number) ?? 0;
  if (unenrolledKids > 0) {
    opportunities.push(
      `${unenrolledKids} copii activi nu sunt înscriși la niciun atelier — pot fi recontactați pentru re-engajare.`,
    );
  }
  const unlinkedKids = (parentStatus.copii_activi_fara_parinte_asociat as number) ?? 0;
  if (unlinkedKids > 0) {
    opportunities.push(
      `${unlinkedKids} copii activi nu au un cont de părinte asociat — invitarea părinților crește comunicarea și retenția.`,
    );
  }
  // Materials gap — types active fără materiale sunt o oportunitate de
  // resourcing pentru traineri.
  const missingMaterials = await toolGetWorkshopsWithoutMaterials(admin);
  const typesWithoutMaterials =
    (missingMaterials.tipuri_fara_materiale as string[]) ?? [];
  if (typesWithoutMaterials.length > 0) {
    opportunities.push(
      `${typesWithoutMaterials.length} tipuri de atelier nu au materiale încărcate — încurajează trainerii să le adauge.`,
    );
  }
  // Trainer load balance — surface trainerul cu cei mai puțini copii ca
  // semnal pentru posibilă realocare.
  const loadSummary = await toolGetTrainerChildrenSummary(admin);
  const trainerList =
    (loadSummary.traineri as Array<{ trainer: string; copii_unici: number }>) ?? [];
  if (trainerList.length >= 2) {
    const least = trainerList[trainerList.length - 1];
    const most = trainerList[0];
    if (most.copii_unici - least.copii_unici >= 5) {
      opportunities.push(
        `Diferență mare de încărcare: ${most.trainer} are ${most.copii_unici} copii, ${least.trainer} are doar ${least.copii_unici}.`,
      );
    }
  }
  return {
    oportunitati: opportunities,
    semnale: {
      top_serii: top,
      serii_sub_utilizate: underused,
      demo_programate: demoTotal,
      copii_fara_atelier: unenrolledKids,
      copii_fara_parinte: unlinkedKids,
      tipuri_fara_materiale: typesWithoutMaterials.length,
      diferenta_incarcare_traineri: trainerList.length >= 2
        ? trainerList[0].copii_unici - trainerList[trainerList.length - 1].copii_unici
        : 0,
    },
  };
}

async function toolGetAdminPriorityList(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const [plan, opportunities, quality, paymentTypes, nameQuality] = await Promise.all([
    toolGetWeeklyActionPlan(admin),
    toolGetGrowthOpportunities(admin),
    toolGetDataQualityIssues(admin),
    toolGetPaymentTypeSummary(admin),
    toolGetWorkshopNameQualityIssues(admin),
  ]);
  return {
    prioritati_imediate: (plan.prioritate_inalta as string[]) ?? [],
    actiuni_saptamana: (plan.actiuni_recomandate as string[]) ?? [],
    oportunitati_de_crestere: (opportunities.oportunitati as string[]) ?? [],
    tip_participare: {
      copii_platitori: paymentTypes.copii_platitori_total,
      copii_gratuiti: paymentTypes.copii_gratuiti_total,
    },
    progres: plan.progres,
    materiale: plan.materiale,
    plati_cu_suma: plan.plati_cu_suma,
    calitate_denumiri_ateliere: {
      nume_cu_litere_mici_count: (nameQuality.nume_cu_litere_mici as string[]).length,
      duplicate_dupa_majuscule_count: (nameQuality.duplicate_dupa_majuscule as unknown[]).length,
      ateliere_active_fara_copii_count: (nameQuality.ateliere_active_fara_copii as string[]).length,
      ateliere_inactive_in_analize_count: (nameQuality.ateliere_inactive_in_analize as string[]).length,
    },
    igiena_date: {
      copii_fara_data_nasterii: quality.copii_fara_data_nasterii,
      copii_fara_telefon_parinte: quality.copii_fara_telefon_parinte,
      ateliere_viitoare_fara_trainer: quality.ateliere_viitoare_fara_trainer,
      cicluri_plata_suspecte: quality.cicluri_plata_suspecte_zero_sedinte,
    },
  };
}

// ── Participation type (paid vs free) ───────────────────────────────────────

/// Lists children with `payment_type = 'free'` — the canonical answer for
/// "copii neplătitori / gratuiți". Never reads payment_cycles; this is a
/// pure children-table read.
async function toolGetFreeParticipants(
  admin: SupabaseClient,
  args: { only_active?: boolean; limit?: number },
): Promise<Record<string, unknown>> {
  const onlyActive = args.only_active !== false;
  const limit = Math.min(Math.max(args.limit ?? 30, 1), 100);

  let q = admin
    .from("children")
    .select(
      "id, first_name, last_name, is_active, parent_name, parent_phone, payment_type",
    )
    .eq("payment_type", "free")
    .order("last_name", { ascending: true });
  if (onlyActive) q = q.eq("is_active", true);

  const { data } = await q;
  const rows = (data ?? []) as Array<{
    id: string;
    first_name: string | null;
    last_name: string | null;
    is_active: boolean;
    parent_name: string | null;
    parent_phone: string | null;
    payment_type: string | null;
  }>;

  if (rows.length === 0) {
    return {
      total: 0,
      copii: [],
      nota: onlyActive
        ? "Nu există copii activi cu participare gratuită."
        : "Nu există copii cu participare gratuită.",
    };
  }

  const ids = rows.map((r) => r.id);

  // Active workshop(s) and last attendance for each child — same
  // join pattern used elsewhere in this file so labels stay consistent.
  const [enrollmentsRes, attendanceRes] = await Promise.all([
    admin
      .from("workshop_enrollments")
      .select(
        "child_id, workshop_series!series_id(title, workshop_type, day_of_week, start_time, end_time)",
      )
      .in("child_id", ids)
      .eq("is_active", true),
    admin
      .from("attendance")
      .select(
        "child_id, status, marked_at, scheduled_workshops!scheduled_workshop_id(title, workshop_date)",
      )
      .in("child_id", ids)
      .eq("is_archived", false)
      .order("marked_at", { ascending: false }),
  ]);

  const enrollmentsByChild = new Map<string, Array<Record<string, unknown>>>();
  for (
    const row of (enrollmentsRes.data ?? []) as Array<{
      child_id: string;
      workshop_series: {
        title: string | null;
        workshop_type: string | null;
        day_of_week: string | null;
        start_time: string | null;
        end_time: string | null;
      } | null;
    }>
  ) {
    const ws = row.workshop_series;
    if (!ws) continue;
    const list = enrollmentsByChild.get(row.child_id) ?? [];
    list.push({
      titlu: ws.title,
      tip: ws.workshop_type,
      zi: ws.day_of_week,
      ora_start: ws.start_time,
      ora_sfarsit: ws.end_time,
    });
    enrollmentsByChild.set(row.child_id, list);
  }

  // First match per child = most recent attendance (the query is ordered desc).
  const lastAttendanceByChild = new Map<string, Record<string, unknown>>();
  for (
    const row of (attendanceRes.data ?? []) as Array<{
      child_id: string;
      status: string | null;
      marked_at: string | null;
      scheduled_workshops:
        | { title: string | null; workshop_date: string | null }
        | null;
    }>
  ) {
    if (lastAttendanceByChild.has(row.child_id)) continue;
    lastAttendanceByChild.set(row.child_id, {
      status: row.status,
      data_atelierului: row.scheduled_workshops?.workshop_date ?? null,
      titlu_atelier: row.scheduled_workshops?.title ?? null,
    });
  }

  const limited = rows.slice(0, limit);
  return {
    total: rows.length,
    activi: rows.filter((r) => r.is_active).length,
    inactivi: rows.filter((r) => !r.is_active).length,
    afisati: limited.length,
    nota: rows.length > limited.length
      ? `Lista a fost limitată la ${limited.length} copii (din ${rows.length}).`
      : undefined,
    copii: limited.map((r) => ({
      nume: fullName(r.first_name, r.last_name),
      activ: r.is_active,
      tip_participare: "gratuit",
      parinte: r.parent_name,
      telefon_parinte: r.parent_phone,
      ateliere_active: enrollmentsByChild.get(r.id) ?? [],
      ultima_prezenta: lastAttendanceByChild.get(r.id) ?? null,
    })),
  };
}

/// Counts children grouped by payment_type — both total and active.
/// Pure children-table read; never touches payment_cycles.
async function toolGetPaymentTypeSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const { data } = await admin
    .from("children")
    .select("payment_type, is_active");
  const rows = (data ?? []) as Array<{
    payment_type: string | null;
    is_active: boolean;
  }>;

  let totalPaid = 0;
  let totalFree = 0;
  let activePaid = 0;
  let activeFree = 0;
  for (const r of rows) {
    const isFree = r.payment_type === "free";
    if (isFree) {
      totalFree += 1;
      if (r.is_active) activeFree += 1;
    } else {
      totalPaid += 1;
      if (r.is_active) activePaid += 1;
    }
  }

  return {
    copii_platitori_total: totalPaid,
    copii_gratuiti_total: totalFree,
    copii_platitori_activi: activePaid,
    copii_gratuiti_activi: activeFree,
    nota:
      "tip_participare = 'gratuit' (children.payment_type='free') înseamnă copil " +
      "cu participare gratuită, NU plată restantă. Pentru plăți restante folosește " +
      "get_payments_due sau get_financial_summary.",
  };
}

// ── Children profile intelligence ─────────────────────────────────────────

function ageFromBirthDate(birthDate: string | null): number | null {
  if (!birthDate) return null;
  const d = new Date(birthDate);
  if (isNaN(d.getTime())) return null;
  const today = new Date();
  let age = today.getFullYear() - d.getFullYear();
  const m = today.getMonth() - d.getMonth();
  if (m < 0 || (m === 0 && today.getDate() < d.getDate())) age -= 1;
  return age;
}

async function toolGetChildrenAgeExtremes(
  admin: SupabaseClient,
  args: { only_active?: boolean },
): Promise<Record<string, unknown>> {
  const onlyActive = args.only_active !== false;
  let q = admin
    .from("children")
    .select("first_name, last_name, birth_date, is_active")
    .not("birth_date", "is", null);
  if (onlyActive) q = q.eq("is_active", true);
  const { data } = await q;
  const rows = (data ?? []) as Array<{
    first_name: string | null;
    last_name: string | null;
    birth_date: string | null;
    is_active: boolean;
  }>;
  if (rows.length === 0) {
    return {
      total_cu_data_nasterii: 0,
      nota:
        "Niciun copil nu are completată data nașterii. Nu pot determina " +
        "extremele de vârstă fără această informație.",
    };
  }
  rows.sort((a, b) => (a.birth_date ?? "").localeCompare(b.birth_date ?? ""));
  const oldest = rows[0];
  const youngest = rows[rows.length - 1];
  return {
    total_cu_data_nasterii: rows.length,
    cel_mai_mare: {
      nume: fullName(oldest.first_name, oldest.last_name),
      data_nasterii: oldest.birth_date,
      varsta: ageFromBirthDate(oldest.birth_date),
      activ: oldest.is_active,
    },
    cel_mai_mic: {
      nume: fullName(youngest.first_name, youngest.last_name),
      data_nasterii: youngest.birth_date,
      varsta: ageFromBirthDate(youngest.birth_date),
      activ: youngest.is_active,
    },
  };
}

async function toolGetChildrenByLastName(
  admin: SupabaseClient,
  args: { last_name: string },
): Promise<Record<string, unknown>> {
  const q = (args.last_name ?? "").trim();
  if (q.length < 2) return { results: [], nota: "Numele este prea scurt." };
  const escaped = q.replace(/%/g, "\\%").replace(/_/g, "\\_");
  const { data } = await admin
    .from("children")
    .select(
      "id, first_name, last_name, is_active, parent_name, parent_phone, birth_date, payment_type",
    )
    .ilike("last_name", `%${escaped}%`)
    .order("last_name");
  const rows = (data ?? []) as Array<{
    id: string;
    first_name: string | null;
    last_name: string | null;
    is_active: boolean;
    parent_name: string | null;
    parent_phone: string | null;
    birth_date: string | null;
    payment_type: string | null;
  }>;
  if (rows.length === 0) {
    return {
      total: 0,
      copii: [],
      nota: `Niciun copil cu numele de familie "${q}".`,
    };
  }
  // Active workshop per child (deduplicated by series).
  const ids = rows.map((r) => r.id);
  const { data: enrolls } = await admin
    .from("workshop_enrollments")
    .select(
      "child_id, workshop_series!series_id(title, workshop_type, day_of_week)",
    )
    .in("child_id", ids)
    .eq("is_active", true);
  const byChild = new Map<string, Array<Record<string, unknown>>>();
  for (
    const e of (enrolls ?? []) as Array<{
      child_id: string;
      workshop_series: {
        title: string | null;
        workshop_type: string | null;
        day_of_week: string | null;
      } | null;
    }>
  ) {
    if (!e.workshop_series) continue;
    const list = byChild.get(e.child_id) ?? [];
    list.push({
      titlu: e.workshop_series.title,
      tip: e.workshop_series.workshop_type,
      zi: e.workshop_series.day_of_week,
    });
    byChild.set(e.child_id, list);
  }
  return {
    total: rows.length,
    copii: rows.map((r) => ({
      nume: fullName(r.first_name, r.last_name),
      activ: r.is_active,
      tip_participare: r.payment_type === "free" ? "gratuit" : "platitor",
      varsta: ageFromBirthDate(r.birth_date),
      parinte: r.parent_name,
      telefon_parinte: r.parent_phone,
      ateliere: byChild.get(r.id) ?? [],
    })),
  };
}

async function toolGetChildrenMissingProfileData(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const { data: kids } = await admin
    .from("children")
    .select(
      "id, first_name, last_name, birth_date, parent_name, parent_phone, payment_type",
    )
    .eq("is_active", true);
  const rows = (kids ?? []) as Array<{
    id: string;
    first_name: string | null;
    last_name: string | null;
    birth_date: string | null;
    parent_name: string | null;
    parent_phone: string | null;
    payment_type: string | null;
  }>;
  const { data: enrolls } = await admin
    .from("workshop_enrollments")
    .select("child_id")
    .eq("is_active", true);
  const enrolled = new Set(
    ((enrolls ?? []) as Array<{ child_id: string }>).map((e) => e.child_id),
  );

  const missingBirth: string[] = [];
  const missingParentName: string[] = [];
  const missingParentPhone: string[] = [];
  const missingWorkshop: string[] = [];
  const missingPaymentType: string[] = [];

  for (const r of rows) {
    const name = fullName(r.first_name, r.last_name);
    if (!r.birth_date) missingBirth.push(name);
    if (!r.parent_name || !r.parent_name.trim()) missingParentName.push(name);
    if (!r.parent_phone || !r.parent_phone.trim()) missingParentPhone.push(name);
    if (!enrolled.has(r.id)) missingWorkshop.push(name);
    if (!r.payment_type) missingPaymentType.push(name);
  }

  return {
    fara_data_nasterii: { numar: missingBirth.length, nume: trim(missingBirth, 25) },
    fara_nume_parinte: {
      numar: missingParentName.length,
      nume: trim(missingParentName, 25),
    },
    fara_telefon_parinte: {
      numar: missingParentPhone.length,
      nume: trim(missingParentPhone, 25),
    },
    fara_atelier_asignat: {
      numar: missingWorkshop.length,
      nume: trim(missingWorkshop, 25),
    },
    fara_tip_participare: {
      numar: missingPaymentType.length,
      nume: trim(missingPaymentType, 25),
    },
    nota: missingPaymentType.length === 0
      ? undefined
      : "Tipul de participare ar trebui completat la fiecare copil (plătitor / gratuit).",
  };
}

// ── Trainer ↔ children relationships ──────────────────────────────────────
//
// Trainer lookup reuses the existing `findTrainerByName` helper defined
// earlier in this file — duplicating it here previously triggered a
// "Identifier 'findTrainerByName' has already been declared" boot error
// in the Edge Function (BOOT_ERROR), which surfaces to the browser as a
// CORS failure because the platform's fallback response misses
// Access-Control-Allow-Headers: content-type.

async function toolGetChildrenByTrainer(
  admin: SupabaseClient,
  args: { trainer_name: string },
): Promise<Record<string, unknown>> {
  const trainer = await findTrainerByName(admin, args.trainer_name ?? "");
  if (!trainer) {
    return { eroare: `Nu am găsit niciun trainer pe nume "${args.trainer_name}".` };
  }
  // Active series owned by this trainer.
  const { data: seriesRows } = await admin
    .from("workshop_series")
    .select("id, title, workshop_type, day_of_week, start_time, end_time")
    .eq("trainer_id", trainer.id)
    .eq("is_active", true)
    .order("day_of_week")
    .order("start_time");
  const series = (seriesRows ?? []) as Array<{
    id: string;
    title: string | null;
    workshop_type: string | null;
    day_of_week: string | null;
    start_time: string | null;
    end_time: string | null;
  }>;
  if (series.length === 0) {
    return {
      trainer: trainer.full,
      ateliere_active: 0,
      total_copii_unici: 0,
      ateliere: [],
      nota: "Trainerul nu are ateliere active.",
    };
  }
  const seriesIds = series.map((s) => s.id);
  const { data: enrollRows } = await admin
    .from("workshop_enrollments")
    .select(
      "series_id, children!inner(id, first_name, last_name, payment_type)",
    )
    .in("series_id", seriesIds)
    .eq("is_active", true);
  const enrollments = (enrollRows ?? []) as Array<{
    series_id: string;
    children: {
      id: string;
      first_name: string | null;
      last_name: string | null;
      payment_type: string | null;
    } | null;
  }>;
  const childrenBySeries = new Map<string, Array<Record<string, unknown>>>();
  const allChildIds = new Set<string>();
  for (const e of enrollments) {
    if (!e.children) continue;
    allChildIds.add(e.children.id);
    const list = childrenBySeries.get(e.series_id) ?? [];
    list.push({
      nume: fullName(e.children.first_name, e.children.last_name),
      tip_participare: e.children.payment_type === "free"
        ? "gratuit"
        : "platitor",
    });
    childrenBySeries.set(e.series_id, list);
  }
  return {
    trainer: trainer.full,
    ateliere_active: series.length,
    total_copii_unici: allChildIds.size,
    ateliere: series.map((s) => ({
      titlu: s.title,
      tip: s.workshop_type,
      zi: s.day_of_week,
      ora_start: s.start_time,
      ora_sfarsit: s.end_time,
      copii: (childrenBySeries.get(s.id) ?? []).sort((a, b) =>
        String(a.nume).localeCompare(String(b.nume))
      ),
      numar_copii: (childrenBySeries.get(s.id) ?? []).length,
    })),
  };
}

async function toolGetTrainerChildrenSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const { data: trainerRows } = await admin
    .from("profiles")
    .select("id, first_name, last_name")
    .eq("role", "trainer");
  const trainers = (trainerRows ?? []) as Array<{
    id: string;
    first_name: string | null;
    last_name: string | null;
  }>;
  const { data: seriesRows } = await admin
    .from("workshop_series")
    .select("id, trainer_id")
    .eq("is_active", true);
  const series = (seriesRows ?? []) as Array<{ id: string; trainer_id: string | null }>;
  const seriesByTrainer = new Map<string, string[]>();
  for (const s of series) {
    if (!s.trainer_id) continue;
    const list = seriesByTrainer.get(s.trainer_id) ?? [];
    list.push(s.id);
    seriesByTrainer.set(s.trainer_id, list);
  }
  const allSeriesIds = series.map((s) => s.id);
  const { data: enrollRows } = await admin
    .from("workshop_enrollments")
    .select("series_id, children!inner(id, payment_type, is_active)")
    .in("series_id", allSeriesIds)
    .eq("is_active", true);
  const enrollments = (enrollRows ?? []) as Array<{
    series_id: string;
    children: { id: string; payment_type: string | null; is_active: boolean } | null;
  }>;
  const result = trainers.map((t) => {
    const mySeries = seriesByTrainer.get(t.id) ?? [];
    const myChildIds = new Set<string>();
    let paid = 0;
    let free = 0;
    for (const e of enrollments) {
      if (!mySeries.includes(e.series_id) || !e.children) continue;
      if (myChildIds.has(e.children.id)) continue;
      myChildIds.add(e.children.id);
      if (e.children.payment_type === "free") free += 1;
      else paid += 1;
    }
    return {
      trainer: fullName(t.first_name, t.last_name),
      ateliere_active: mySeries.length,
      copii_unici: myChildIds.size,
      copii_platitori: paid,
      copii_gratuiti: free,
    };
  });
  result.sort((a, b) => b.copii_unici - a.copii_unici);
  return { traineri: result };
}

async function toolGetTrainersWithPaymentRisk(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  // due/overdue cycles for paid children only.
  const { data: cycleRows } = await admin
    .from("payment_cycles")
    .select("child_id, status, children!inner(payment_type, first_name, last_name)")
    .in("status", ["due", "overdue"])
    .eq("children.payment_type", "paid");
  const cycles = (cycleRows ?? []) as Array<{
    child_id: string;
    status: string | null;
    children: {
      payment_type: string | null;
      first_name: string | null;
      last_name: string | null;
    } | null;
  }>;
  const childIds = Array.from(new Set(cycles.map((c) => c.child_id)));
  if (childIds.length === 0) {
    return { traineri: [], nota: "Niciun copil plătitor cu plăți restante." };
  }
  const { data: enrollRows } = await admin
    .from("workshop_enrollments")
    .select(
      "child_id, workshop_series!series_id(trainer_id, profiles:trainer_id(first_name, last_name))",
    )
    .in("child_id", childIds)
    .eq("is_active", true);
  const enrollments = (enrollRows ?? []) as Array<{
    child_id: string;
    workshop_series: {
      trainer_id: string | null;
      profiles: { first_name: string | null; last_name: string | null } | null;
    } | null;
  }>;
  type Bucket = {
    name: string;
    childIds: Set<string>;
    childNames: Set<string>;
  };
  const byTrainer = new Map<string, Bucket>();
  const childNameById = new Map<string, string>();
  for (const c of cycles) {
    if (!c.children) continue;
    childNameById.set(
      c.child_id,
      fullName(c.children.first_name, c.children.last_name),
    );
  }
  for (const e of enrollments) {
    const ws = e.workshop_series;
    if (!ws || !ws.trainer_id) continue;
    const trainerName = fullName(
      ws.profiles?.first_name,
      ws.profiles?.last_name,
    );
    const bucket = byTrainer.get(ws.trainer_id) ??
      { name: trainerName, childIds: new Set(), childNames: new Set() };
    bucket.childIds.add(e.child_id);
    const childName = childNameById.get(e.child_id);
    if (childName) bucket.childNames.add(childName);
    byTrainer.set(ws.trainer_id, bucket);
  }
  const result = Array.from(byTrainer.values())
    .map((b) => ({
      trainer: b.name,
      copii_cu_plati_restante: b.childIds.size,
      nume_copii: Array.from(b.childNames).sort().slice(0, 15),
    }))
    .sort((a, b) => b.copii_cu_plati_restante - a.copii_cu_plati_restante);
  return { traineri: result };
}

// ── Child progress ────────────────────────────────────────────────────────

/// Wraps a `child_progress` read so missing-table errors degrade to a
/// friendly note instead of a generic dispatcher failure. The user docs
/// flag the table as "future-feature placeholder, unknown if present".
async function safeProgressFetch<T>(
  admin: SupabaseClient,
  build: () => Promise<{ data: T | null; error: unknown }>,
): Promise<{ data: T | null; missing: boolean }> {
  try {
    const res = await build();
    if (res.error) {
      const code = (res.error as { code?: string })?.code;
      if (code === "42P01" || code === "PGRST205") {
        return { data: null, missing: true };
      }
    }
    return { data: res.data as T | null, missing: false };
  } catch (_) {
    return { data: null, missing: true };
  }
}

async function toolGetProgressSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const monthStart = ymd(new Date(new Date().getFullYear(), new Date().getMonth(), 1));
  const res = await safeProgressFetch<
    Array<{
      child_id: string | null;
      created_by: string | null;
      status: string | null;
      created_at: string | null;
    }>
  >(admin, async () => {
    return await admin
      .from("child_progress")
      .select("child_id, created_by, status, created_at");
  });
  if (res.missing) {
    return {
      nota:
        "Funcția 'progres copii' nu este încă activată în această instanță. " +
        "Tabelul child_progress nu există.",
    };
  }
  const rows = res.data ?? [];
  if (rows.length === 0) {
    return {
      total: 0,
      nota: "Nu există observații de progres înregistrate.",
    };
  }
  const totalLuna = rows.filter(
    (r) => (r.created_at ?? "").slice(0, 10) >= monthStart,
  ).length;
  const byStatus: Record<string, number> = {};
  const byChild = new Map<string, number>();
  const byTrainer = new Map<string, number>();
  for (const r of rows) {
    const status = r.status ?? "necunoscut";
    byStatus[status] = (byStatus[status] ?? 0) + 1;
    if (r.child_id) byChild.set(r.child_id, (byChild.get(r.child_id) ?? 0) + 1);
    if (r.created_by) {
      byTrainer.set(r.created_by, (byTrainer.get(r.created_by) ?? 0) + 1);
    }
  }
  const topChildIds = Array.from(byChild.entries())
    .sort(([, a], [, b]) => b - a).slice(0, 5).map(([id]) => id);
  const topTrainerIds = Array.from(byTrainer.entries())
    .sort(([, a], [, b]) => b - a).slice(0, 5).map(([id]) => id);
  const childNames = await fetchChildNames(admin, topChildIds);
  const trainerNames = await fetchTrainerNames(admin, topTrainerIds);
  return {
    total: rows.length,
    luna_curenta: totalLuna,
    pe_status: byStatus,
    top_copii_dupa_observatii: topChildIds.map((id) => ({
      nume: childNames.get(id) ?? "Necunoscut",
      observatii: byChild.get(id) ?? 0,
    })),
    top_traineri_dupa_observatii: topTrainerIds.map((id) => ({
      trainer: trainerNames.get(id) ?? "Necunoscut",
      observatii: byTrainer.get(id) ?? 0,
    })),
  };
}

async function toolGetRecentProgressNotes(
  admin: SupabaseClient,
  args: { limit?: number; days?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 10, 1), 50);
  const days = Math.min(Math.max(args.days ?? 30, 1), 365);
  const since = ymd(addDays(new Date(), -days));
  const res = await safeProgressFetch<
    Array<{
      child_id: string | null;
      created_by: string | null;
      title: string | null;
      note: string | null;
      status: string | null;
      created_at: string | null;
    }>
  >(admin, async () => {
    return await admin
      .from("child_progress")
      .select("child_id, created_by, title, note, status, created_at")
      .gte("created_at", since)
      .order("created_at", { ascending: false })
      .limit(limit);
  });
  if (res.missing) {
    return {
      nota:
        "Funcția 'progres copii' nu este încă activată în această instanță.",
    };
  }
  const rows = res.data ?? [];
  if (rows.length === 0) {
    return {
      total: 0,
      observatii: [],
      nota: `Nu există observații de progres în ultimele ${days} de zile.`,
    };
  }
  const childIds = rows.map((r) => r.child_id ?? "").filter(Boolean);
  const trainerIds = rows.map((r) => r.created_by ?? "").filter(Boolean);
  const [childNames, trainerNames] = await Promise.all([
    fetchChildNames(admin, childIds),
    fetchTrainerNames(admin, trainerIds),
  ]);
  return {
    fereastra_zile: days,
    total: rows.length,
    observatii: rows.map((r) => ({
      copil: r.child_id ? (childNames.get(r.child_id) ?? "Necunoscut") : null,
      trainer: r.created_by
        ? (trainerNames.get(r.created_by) ?? "Necunoscut")
        : null,
      titlu: r.title,
      status: r.status,
      data: r.created_at?.slice(0, 10) ?? null,
      preview: (r.note ?? "").slice(0, 160),
    })),
  };
}

async function toolGetChildrenByProgressStatus(
  admin: SupabaseClient,
  args: { status: "completed" | "in_progress" | "needs_review" },
): Promise<Record<string, unknown>> {
  const res = await safeProgressFetch<
    Array<{
      child_id: string | null;
      created_by: string | null;
      title: string | null;
      status: string | null;
      created_at: string | null;
    }>
  >(admin, async () => {
    return await admin
      .from("child_progress")
      .select("child_id, created_by, title, status, created_at")
      .eq("status", args.status)
      .order("created_at", { ascending: false });
  });
  if (res.missing) {
    return {
      nota:
        "Funcția 'progres copii' nu este încă activată în această instanță.",
    };
  }
  const rows = res.data ?? [];
  // Keep only the most recent note per child.
  const latestByChild = new Map<string, typeof rows[number]>();
  for (const r of rows) {
    if (!r.child_id) continue;
    if (!latestByChild.has(r.child_id)) latestByChild.set(r.child_id, r);
  }
  const childIds = Array.from(latestByChild.keys());
  if (childIds.length === 0) {
    return {
      status: args.status,
      total: 0,
      copii: [],
      nota: `Niciun copil cu status "${args.status}".`,
    };
  }
  const trainerIds = Array.from(latestByChild.values())
    .map((r) => r?.created_by ?? "")
    .filter(Boolean);
  const [childNames, trainerNames] = await Promise.all([
    fetchChildNames(admin, childIds),
    fetchTrainerNames(admin, trainerIds),
  ]);
  return {
    status: args.status,
    total: childIds.length,
    copii: childIds.map((id) => {
      const r = latestByChild.get(id)!;
      return {
        copil: childNames.get(id) ?? "Necunoscut",
        ultima_observatie: r.title,
        data: r.created_at?.slice(0, 10) ?? null,
        trainer: r.created_by
          ? (trainerNames.get(r.created_by) ?? "Necunoscut")
          : null,
      };
    }),
  };
}

async function toolGetChildProgressDetails(
  admin: SupabaseClient,
  args: { child_name: string },
): Promise<Record<string, unknown>> {
  const child = await findChildByName(admin, args.child_name ?? "");
  if (!child) return { eroare: `Nu am găsit copilul "${args.child_name}".` };
  const res = await safeProgressFetch<
    Array<{
      created_by: string | null;
      title: string | null;
      note: string | null;
      status: string | null;
      created_at: string | null;
    }>
  >(admin, async () => {
    return await admin
      .from("child_progress")
      .select("created_by, title, note, status, created_at")
      .eq("child_id", child.id)
      .order("created_at", { ascending: false });
  });
  if (res.missing) {
    return {
      copil: child.full,
      nota:
        "Funcția 'progres copii' nu este încă activată în această instanță.",
    };
  }
  const rows = res.data ?? [];
  if (rows.length === 0) {
    return {
      copil: child.full,
      total: 0,
      istoric: [],
      nota: "Nu există observații de progres pentru acest copil.",
    };
  }
  const trainerIds = rows.map((r) => r.created_by ?? "").filter(Boolean);
  const trainerNames = await fetchTrainerNames(admin, trainerIds);
  return {
    copil: child.full,
    total: rows.length,
    istoric: rows.map((r) => ({
      titlu: r.title,
      status: r.status,
      data: r.created_at?.slice(0, 10) ?? null,
      trainer: r.created_by
        ? (trainerNames.get(r.created_by) ?? "Necunoscut")
        : null,
      preview: (r.note ?? "").slice(0, 160),
    })),
  };
}

// ── Lesson materials ──────────────────────────────────────────────────────

async function safeMaterialsFetch<T>(
  admin: SupabaseClient,
  build: () => Promise<{ data: T | null; error: unknown }>,
): Promise<{ data: T | null; missing: boolean }> {
  try {
    const res = await build();
    if (res.error) {
      const code = (res.error as { code?: string })?.code;
      if (code === "42P01" || code === "PGRST205") {
        return { data: null, missing: true };
      }
    }
    return { data: res.data as T | null, missing: false };
  } catch (_) {
    return { data: null, missing: true };
  }
}

const MATERIALS_MISSING_NOTE =
  "Funcția 'materiale de lecție' nu este încă activată în această instanță.";

async function toolGetMaterialsSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const monthStart = ymd(new Date(new Date().getFullYear(), new Date().getMonth(), 1));
  const res = await safeMaterialsFetch<
    Array<{
      workshop_type: string | null;
      uploaded_by: string | null;
      created_at: string | null;
      is_active: boolean | null;
    }>
  >(admin, async () => {
    return await admin
      .from("lesson_materials")
      .select("workshop_type, uploaded_by, created_at, is_active");
  });
  if (res.missing) return { nota: MATERIALS_MISSING_NOTE };
  const rows = (res.data ?? []).filter((r) => r.is_active !== false);
  if (rows.length === 0) {
    return { total: 0, nota: "Niciun material activ înregistrat." };
  }
  const totalLuna = rows.filter(
    (r) => (r.created_at ?? "").slice(0, 10) >= monthStart,
  ).length;
  const byType: Record<string, number> = {};
  const byUploader = new Map<string, number>();
  for (const r of rows) {
    const t = (r.workshop_type ?? "Necunoscut").trim() || "Necunoscut";
    byType[t] = (byType[t] ?? 0) + 1;
    if (r.uploaded_by) {
      byUploader.set(r.uploaded_by, (byUploader.get(r.uploaded_by) ?? 0) + 1);
    }
  }
  const topIds = Array.from(byUploader.entries())
    .sort(([, a], [, b]) => b - a).slice(0, 5).map(([id]) => id);
  const uploaderNames = await fetchTrainerNames(admin, topIds);
  return {
    total_active: rows.length,
    incarcate_luna: totalLuna,
    pe_tip_atelier: Object.entries(byType)
      .map(([tip, numar]) => ({ tip, numar }))
      .sort((a, b) => b.numar - a.numar),
    top_uploaderi: topIds.map((id) => ({
      uploader: uploaderNames.get(id) ?? "Necunoscut",
      numar: byUploader.get(id) ?? 0,
    })),
  };
}

async function toolGetMaterialsByWorkshopType(
  admin: SupabaseClient,
  args: { workshop_type: string },
): Promise<Record<string, unknown>> {
  const q = (args.workshop_type ?? "").trim();
  if (!q) return { eroare: "Tipul de atelier este obligatoriu." };
  const escaped = q.replace(/%/g, "\\%").replace(/_/g, "\\_");
  const res = await safeMaterialsFetch<
    Array<{
      title: string | null;
      description: string | null;
      file_name: string | null;
      uploaded_by: string | null;
      created_at: string | null;
      workshop_type: string | null;
      scheduled_workshop_id: string | null;
    }>
  >(admin, async () => {
    return await admin
      .from("lesson_materials")
      .select(
        "title, description, file_name, uploaded_by, created_at, workshop_type, scheduled_workshop_id",
      )
      .ilike("workshop_type", `%${escaped}%`)
      .eq("is_active", true)
      .order("created_at", { ascending: false })
      .limit(50);
  });
  if (res.missing) return { nota: MATERIALS_MISSING_NOTE };
  const rows = res.data ?? [];
  if (rows.length === 0) {
    return {
      tip_atelier: q,
      total: 0,
      materiale: [],
      nota: `Niciun material pentru tipul "${q}".`,
    };
  }
  const uploaderIds = rows.map((r) => r.uploaded_by ?? "").filter(Boolean);
  const uploaderNames = await fetchTrainerNames(admin, uploaderIds);
  return {
    tip_atelier: q,
    total: rows.length,
    materiale: rows.map((r) => ({
      titlu: r.title,
      descriere: r.description,
      fisier: r.file_name,
      tip: r.workshop_type,
      incarcat_de: r.uploaded_by
        ? (uploaderNames.get(r.uploaded_by) ?? "Necunoscut")
        : null,
      data: r.created_at?.slice(0, 10) ?? null,
    })),
  };
}

async function toolGetRecentMaterials(
  admin: SupabaseClient,
  args: { limit?: number; days?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 10, 1), 50);
  const days = Math.min(Math.max(args.days ?? 30, 1), 365);
  const since = ymd(addDays(new Date(), -days));
  const res = await safeMaterialsFetch<
    Array<{
      title: string | null;
      workshop_type: string | null;
      uploaded_by: string | null;
      created_at: string | null;
    }>
  >(admin, async () => {
    return await admin
      .from("lesson_materials")
      .select("title, workshop_type, uploaded_by, created_at")
      .eq("is_active", true)
      .gte("created_at", since)
      .order("created_at", { ascending: false })
      .limit(limit);
  });
  if (res.missing) return { nota: MATERIALS_MISSING_NOTE };
  const rows = res.data ?? [];
  if (rows.length === 0) {
    return {
      fereastra_zile: days,
      total: 0,
      materiale: [],
      nota: `Niciun material încărcat în ultimele ${days} de zile.`,
    };
  }
  const uploaderIds = rows.map((r) => r.uploaded_by ?? "").filter(Boolean);
  const uploaderNames = await fetchTrainerNames(admin, uploaderIds);
  return {
    fereastra_zile: days,
    total: rows.length,
    materiale: rows.map((r) => ({
      titlu: r.title,
      tip: r.workshop_type,
      incarcat_de: r.uploaded_by
        ? (uploaderNames.get(r.uploaded_by) ?? "Necunoscut")
        : null,
      data: r.created_at?.slice(0, 10) ?? null,
    })),
  };
}

async function toolGetWorkshopsWithoutMaterials(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  // Active workshop types come from workshop_series — independent of
  // whether lesson_materials is enabled.
  const { data: seriesRows } = await admin
    .from("workshop_series")
    .select("workshop_type")
    .eq("is_active", true);
  const activeTypes = new Set<string>();
  for (
    const s of (seriesRows ?? []) as Array<{ workshop_type: string | null }>
  ) {
    const t = (s.workshop_type ?? "").trim();
    if (t) activeTypes.add(t);
  }
  if (activeTypes.size === 0) {
    return { tipuri_fara_materiale: [], nota: "Nu există tipuri de atelier active." };
  }
  const res = await safeMaterialsFetch<
    Array<{ workshop_type: string | null }>
  >(admin, async () => {
    return await admin
      .from("lesson_materials")
      .select("workshop_type")
      .eq("is_active", true);
  });
  if (res.missing) {
    return {
      tipuri_fara_materiale: Array.from(activeTypes).sort(),
      nota:
        MATERIALS_MISSING_NOTE +
        " Toate tipurile active sunt listate ca 'fără materiale'.",
    };
  }
  const haveMaterials = new Set<string>();
  for (const r of res.data ?? []) {
    const t = (r.workshop_type ?? "").trim();
    if (t) haveMaterials.add(t);
  }
  const missing = Array.from(activeTypes).filter(
    (t) => !haveMaterials.has(t),
  ).sort();
  return {
    total: missing.length,
    tipuri_fara_materiale: missing,
  };
}

// ── Payment intelligence ──────────────────────────────────────────────────

// Deprecated stub — the tool schema was removed on 2026-08-14 because
// the app does not store per-cycle amounts. Kept only so that the
// composite tools (weekly_action_plan, admin_priority_list) that used
// to call it don't break. Always returns nulls + a fixed note; never
// hits the DB.
function toolGetPaymentAmountSummary(
  _admin: SupabaseClient,
  _args: { year?: number; month?: number },
): Promise<Record<string, unknown>> {
  return Promise.resolve({
    nota:
      "Aplicația nu stochează valori monetare per ciclu de plată. " +
      "Pentru sume monetare, folosește rapoartele externe.",
    suma_incasata: null,
    suma_restanta: null,
    cicluri_incasate: null,
    cicluri_restante: null,
  });
}

async function toolGetRecentConfirmedPayments(
  admin: SupabaseClient,
  args: { days?: number; limit?: number },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 30, 1), 365);
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const since = ymd(addDays(new Date(), -days));
  // Note (2026-08-14): amount + currency deliberately NOT selected.
  // Every payment_cycles row has amount IS NULL in production; exposing
  // the column tempted the model to hallucinate values. Reports with
  // monetary figures are handled outside the app.
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "child_id, paid_at, payment_method, status, " +
        "children!inner(first_name, last_name, payment_type), " +
        "confirmed_by",
    )
    .in("status", ["paid", "paid_advance"])
    .eq("children.payment_type", "paid")
    .gte("paid_at", since)
    .order("paid_at", { ascending: false })
    .limit(limit);
  const rows = (data ?? []) as Array<{
    child_id: string;
    paid_at: string | null;
    payment_method: string | null;
    status: string | null;
    children: {
      first_name: string | null;
      last_name: string | null;
      payment_type: string | null;
    } | null;
    confirmed_by: string | null;
  }>;
  const trainerIds = rows.map((r) => r.confirmed_by ?? "").filter(Boolean);
  const confirmerNames = await fetchTrainerNames(admin, trainerIds);
  return {
    fereastra_zile: days,
    total: rows.length,
    plati: rows.map((r) => ({
      copil: r.children
        ? fullName(r.children.first_name, r.children.last_name)
        : null,
      data: r.paid_at?.slice(0, 10) ?? null,
      metoda: (r.payment_method ?? "").toUpperCase() || null,
      confirmat_de: r.confirmed_by
        ? (confirmerNames.get(r.confirmed_by) ?? "Necunoscut")
        : null,
      status: r.status,
    })),
  };
}

async function toolGetChildrenNearPaymentCycle(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  // Since 2026-08-20 cycles are per (child, series). Count PRESENT rows
  // per (child, series) that are still in the open block
  // (payment_cycle_id IS NULL) and surface those with exactly 3 —
  // meaning one more PRESENT closes the cycle for that specific
  // workshop. Cross-series aggregates are wrong here: 2 Robotică + 1
  // Engleză is not "near a cycle" for either workshop.
  const { data: attRows } = await admin
    .from("attendance")
    .select(
      "child_id, status, children!inner(payment_type, first_name, last_name, is_active), " +
        "scheduled_workshops!scheduled_workshop_id(title, workshop_date, series_id, recurring_series_id, workshop_series!series_id(title))",
    )
    .is("payment_cycle_id", null)
    .eq("is_archived", false)
    .eq("status", "present")
    .eq("children.payment_type", "paid")
    .eq("children.is_active", true);
  const rows = (attRows ?? []) as Array<{
    child_id: string;
    status: string | null;
    children: {
      payment_type: string | null;
      first_name: string | null;
      last_name: string | null;
      is_active: boolean;
    } | null;
    scheduled_workshops: {
      title: string | null;
      workshop_date: string | null;
      series_id: string | null;
      recurring_series_id: string | null;
      workshop_series: { title: string | null } | null;
    } | null;
  }>;
  type Bucket = {
    name: string;
    seriesTitle: string;
    present: number;
    lastDate: string | null;
    lastWorkshop: string | null;
  };
  const byKey = new Map<string, Bucket>();
  for (const r of rows) {
    if (!r.children || !r.scheduled_workshops) continue;
    const sid = r.scheduled_workshops.series_id ??
      r.scheduled_workshops.recurring_series_id;
    if (!sid) continue;
    const key = `${r.child_id}::${sid}`;
    const b = byKey.get(key) ?? {
      name: fullName(r.children.first_name, r.children.last_name),
      seriesTitle: r.scheduled_workshops.workshop_series?.title ??
        r.scheduled_workshops.title ??
        "Atelier",
      present: 0,
      lastDate: null,
      lastWorkshop: null,
    };
    b.present += 1;
    const wsDate = r.scheduled_workshops.workshop_date;
    if (wsDate && (b.lastDate == null || wsDate > b.lastDate)) {
      b.lastDate = wsDate;
      b.lastWorkshop = r.scheduled_workshops.title;
    }
    byKey.set(key, b);
  }
  const near = Array.from(byKey.values())
    .filter((b) => b.present === 3)
    .sort((a, b) => (a.lastDate ?? "").localeCompare(b.lastDate ?? ""));
  return {
    total: near.length,
    copii: near.map((b) => ({
      copil: b.name,
      atelier: b.seriesTitle,
      prezente_in_ciclul_curent: b.present,
      ultima_prezenta: b.lastDate,
      ultimul_atelier: b.lastWorkshop,
    })),
    nota:
      "Rezultat per (copil, atelier). Un copil poate apărea de mai multe " +
      "ori dacă e aproape de ciclu la mai multe ateliere simultan.",
  };
}

// ── Workshop attendance rankings + name quality ──────────────────────────

async function toolGetAttendanceByWorkshopRankings(
  admin: SupabaseClient,
  args: { days?: number; include_zero_sample?: boolean },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 90, 7), 365);
  const since = ymd(addDays(new Date(), -days));
  const includeZero = args.include_zero_sample === true;
  const { data } = await admin
    .from("attendance")
    .select(
      "status, scheduled_workshops!scheduled_workshop_id(title)",
    )
    .eq("is_archived", false)
    .gte("marked_at", since);
  const rows = (data ?? []) as Array<{
    status: string | null;
    scheduled_workshops: { title: string | null } | null;
  }>;
  type Bucket = { present: number; absent: number; motivated: number; total: number };
  const byTitle = new Map<string, Bucket>();
  for (const r of rows) {
    const title = (r.scheduled_workshops?.title ?? "").trim();
    if (!title) continue;
    const b = byTitle.get(title) ?? { present: 0, absent: 0, motivated: 0, total: 0 };
    b.total += 1;
    if (r.status === "present") b.present += 1;
    else if (r.status === "absent") b.absent += 1;
    else if (r.status === "motivated") b.motivated += 1;
    byTitle.set(title, b);
  }
  const entries = Array.from(byTitle.entries())
    .filter(([, b]) => includeZero ? true : b.total >= 3)
    .map(([title, b]) => ({
      atelier: title,
      total_prezente_marcate: b.total,
      prezente: b.present,
      absente: b.absent,
      motivate: b.motivated,
      rata_prezenta_procent: b.total === 0
        ? 0
        : Math.round((b.present / b.total) * 100),
    }));
  const best = [...entries].sort((a, b) =>
    b.rata_prezenta_procent - a.rata_prezenta_procent ||
    b.total_prezente_marcate - a.total_prezente_marcate
  ).slice(0, 5);
  const worst = [...entries].sort((a, b) =>
    a.rata_prezenta_procent - b.rata_prezenta_procent ||
    b.total_prezente_marcate - a.total_prezente_marcate
  ).slice(0, 5);
  return {
    fereastra_zile: days,
    total_ateliere_evaluate: entries.length,
    cele_mai_bune: best,
    cele_mai_slabe: worst,
    nota: includeZero
      ? "Inclus atelierele cu 0–2 ședințe marcate (set de date prea mic)."
      : "Au fost excluse atelierele cu mai puțin de 3 ședințe marcate.",
  };
}

async function toolGetWorkshopNameQualityIssues(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const { data: seriesData } = await admin
    .from("workshop_series")
    .select("title, is_active");
  const series = (seriesData ?? []) as Array<{
    title: string | null;
    is_active: boolean | null;
  }>;
  const lowercaseTitles: string[] = [];
  const titlesByLower = new Map<string, Set<string>>();
  for (const s of series) {
    const t = (s.title ?? "").trim();
    if (!t) continue;
    if (t === t.toLowerCase() && t !== t.toUpperCase()) lowercaseTitles.push(t);
    const lower = t.toLowerCase();
    const set = titlesByLower.get(lower) ?? new Set();
    set.add(t);
    titlesByLower.set(lower, set);
  }
  const duplicateByCase = Array.from(titlesByLower.values())
    .filter((s) => s.size > 1)
    .map((s) => Array.from(s));

  // Active series with zero active enrollments.
  const { data: activeSeries } = await admin
    .from("workshop_series")
    .select("id, title")
    .eq("is_active", true);
  const activeIds = ((activeSeries ?? []) as Array<{ id: string; title: string | null }>);
  const { data: enrollRows } = await admin
    .from("workshop_enrollments")
    .select("series_id")
    .eq("is_active", true);
  const enrolled = new Set(
    ((enrollRows ?? []) as Array<{ series_id: string }>).map((e) => e.series_id),
  );
  const activeWithoutChildren = activeIds
    .filter((s) => !enrolled.has(s.id))
    .map((s) => (s.title ?? "").trim())
    .filter(Boolean);

  // Inactive series that still received attendance rows recently.
  const since = ymd(addDays(new Date(), -90));
  const { data: recentAtt } = await admin
    .from("attendance")
    .select("scheduled_workshops!scheduled_workshop_id(title, recurring_series_id)")
    .eq("is_archived", false)
    .gte("marked_at", since);
  const inactiveSeriesIds = series.filter((s) => s.is_active === false);
  const inactiveTitles = new Set(
    inactiveSeriesIds
      .map((s) => (s.title ?? "").trim())
      .filter(Boolean)
      .map((t) => t.toLowerCase()),
  );
  const inactiveAppearing = new Set<string>();
  for (
    const r of (recentAtt ?? []) as Array<{
      scheduled_workshops:
        | { title: string | null; recurring_series_id: string | null }
        | null;
    }>
  ) {
    const t = (r.scheduled_workshops?.title ?? "").trim();
    if (t && inactiveTitles.has(t.toLowerCase())) inactiveAppearing.add(t);
  }

  return {
    nume_cu_litere_mici: Array.from(new Set(lowercaseTitles)).sort(),
    duplicate_dupa_majuscule: duplicateByCase,
    ateliere_active_fara_copii: Array.from(new Set(activeWithoutChildren)).sort(),
    ateliere_inactive_in_analize: Array.from(inactiveAppearing).sort(),
  };
}

function toolGetCenterInfo(): Record<string, unknown> {
  return {
    nume: "Tales & Tech HUB",
    locatie: "Suceava, Strada Universității nr. 32 (vizavi de Parcul Universității)",
    program: {
      luni_vineri: "10:00 – 19:00",
      sambata: "10:00 – 13:00",
    },
    ateliere_oferite: [
      "Robotică",
      "Programare și Inteligență Artificială",
      "Lectură și Artă Ilustrativă",
      "Modelare și Imprimare 3D",
    ],
    grupe: "Maxim 10 copii pe grupă, vârsta 6–14 ani.",
  };
}

/**
 * Maps a tool name to the human-readable data-source labels it draws
 * from. The Flutter client surfaces these as the "Date analizate: ..."
 * footer. Composite / overview tools list ALL the underlying categories
 * because they fan out internally without going through the OpenAI
 * tool loop, so their inner reads would otherwise be invisible.
 */
function sourcesFor(toolName: string): string[] {
  const MAP: Record<string, string[]> = {
    // Copii
    "get_children_summary": ["Copii"],
    "search_child_by_name": ["Copii"],
    "get_child_details": ["Copii", "Ateliere", "Prezențe", "Plăți"],
    "get_child_profile": ["Copii", "Ateliere", "Prezențe", "Plăți"],
    "get_child_active_workshops": ["Ateliere"],
    "get_child_recent_activity": ["Prezențe"],
    "get_children_without_active_workshop": ["Copii", "Ateliere"],
    "get_children_with_multiple_workshops": ["Copii", "Ateliere"],
    "get_children_by_workshop_type": ["Copii", "Ateliere"],
    "get_new_children_this_month": ["Copii"],
    "get_inactive_children": ["Copii"],
    "get_children_birthdays_upcoming": ["Copii"],
    // Prezențe
    "get_attendance_summary": ["Prezențe"],
    "get_attendance_by_date": ["Prezențe"],
    "get_attendance_by_workshop": ["Prezențe", "Ateliere"],
    "get_attendance_by_trainer": ["Prezențe", "Traineri"],
    "get_top_children_attendance": ["Prezențe", "Copii"],
    "get_children_with_consecutive_absences": ["Prezențe", "Copii"],
    "get_motivated_absences": ["Prezențe"],
    "compare_attendance_periods": ["Prezențe"],
    "get_workshop_attendance_analysis": ["Prezențe", "Ateliere"],
    // Ateliere
    "get_workshops": ["Ateliere"],
    "get_workshops_by_type": ["Ateliere"],
    "get_workshops_by_trainer": ["Ateliere", "Traineri"],
    "get_active_workshop_series": ["Ateliere"],
    "get_workshop_children": ["Ateliere", "Copii"],
    "get_most_popular_workshops": ["Ateliere"],
    "get_workshops_without_children": ["Ateliere"],
    "get_workshops_without_trainer": ["Ateliere"],
    "get_workshop_capacity_summary": ["Ateliere"],
    // Traineri
    "get_trainers_summary": ["Traineri"],
    "get_trainer_profile": ["Traineri"],
    "get_trainer_workload": ["Traineri"],
    "get_trainer_week_schedule": ["Traineri", "Ateliere"],
    // Părinți
    "get_parent_account_status": ["Părinți", "Copii"],
    "search_parent_by_name_or_email": ["Părinți"],
    "get_parent_children": ["Părinți", "Copii"],
    "get_pending_parent_setups": ["Părinți"],
    "get_expired_parent_setups": ["Părinți"],
    // Plăți
    "get_payments_due": ["Plăți"],
    "get_financial_summary": ["Plăți"],
    "get_payments_by_method": ["Plăți"],
    "get_advance_paid_cycles": ["Plăți"],
    "get_cancelled_payment_cycles": ["Plăți"],
    "get_payment_cycles_by_child": ["Plăți", "Copii"],
    // Ateliere demo
    "get_demo_workshops_summary": ["Ateliere demo"],
    // Notificări
    "get_notifications_summary": ["Notificări"],
    "get_recent_notifications": ["Notificări"],
    // Overview composites
    "get_dashboard_summary": ["Copii", "Ateliere", "Plăți", "Prezențe"],
    "get_center_overview": ["Copii", "Ateliere", "Plăți", "Prezențe"],
    "get_today_summary": ["Ateliere", "Prezențe"],
    "get_week_summary": ["Ateliere", "Prezențe"],
    "get_month_summary": ["Ateliere", "Prezențe", "Plăți", "Copii"],
    "get_important_alerts": ["Plăți", "Ateliere"],
    "get_data_quality_issues": ["Calitatea datelor"],
    // Risc
    "get_risk_children": ["Copii", "Prezențe", "Plăți"],
    // Insight composites
    "get_weekly_action_plan": ["Prezențe", "Plăți", "Ateliere", "Copii"],
    "get_growth_opportunities":
      ["Ateliere", "Ateliere demo", "Părinți", "Copii"],
    "get_admin_priority_list":
      ["Prezențe", "Plăți", "Ateliere", "Copii", "Calitatea datelor"],
    // Centru
    "get_center_info": ["Centru"],
    // Tip participare (paid vs free)
    "get_free_participants": ["Copii", "Ateliere", "Prezențe"],
    "get_payment_type_summary": ["Copii"],
    // Profil copii
    "get_children_age_extremes": ["Copii"],
    "get_children_by_last_name": ["Copii", "Ateliere"],
    "get_children_missing_profile_data": ["Copii", "Ateliere", "Calitatea datelor"],
    // Relații trainer ↔ copii
    "get_children_by_trainer": ["Traineri", "Ateliere", "Copii"],
    "get_trainer_children_summary": ["Traineri", "Ateliere", "Copii"],
    "get_trainers_with_payment_risk": ["Traineri", "Ateliere", "Copii", "Plăți"],
    // Progres copii
    "get_progress_summary": ["Progres"],
    "get_recent_progress_notes": ["Progres", "Copii", "Traineri"],
    "get_children_by_progress_status": ["Progres", "Copii", "Traineri"],
    "get_child_progress_details": ["Progres", "Copii", "Traineri"],
    // Materiale lecții
    "get_materials_summary": ["Materiale"],
    "get_materials_by_workshop_type": ["Materiale"],
    "get_recent_materials": ["Materiale"],
    "get_workshops_without_materials": ["Materiale", "Ateliere"],
    // Plăți avansate
    "get_recent_confirmed_payments": ["Plăți", "Copii"],
    "get_children_near_payment_cycle": ["Plăți", "Prezențe", "Copii"],
    // Calitate ateliere
    "get_attendance_by_workshop_rankings": ["Prezențe", "Ateliere"],
    "get_workshop_name_quality_issues": ["Ateliere", "Calitatea datelor"],
    "run_read_query": ["Interogare SQL ad-hoc"],
  };
  return MAP[toolName] ?? [];
}

/** Rough size estimate for a tool result, used for logging only. */
function approxRowCount(result: unknown): number {
  if (result == null) return 0;
  if (Array.isArray(result)) return result.length;
  if (typeof result === "object") {
    let total = 0;
    for (const v of Object.values(result as Record<string, unknown>)) {
      if (Array.isArray(v)) total += v.length;
    }
    return total;
  }
  return 0;
}

// ── Escape-hatch: run_read_query ────────────────────────────────────────────

/// Column names (or fragments) that must NEVER leave the edge function.
/// Matched case-insensitively against every returned column key. Any row
/// key whose lowercase form contains one of these substrings is stripped
/// before the model sees the response. Only true secrets belong here —
/// we deliberately do NOT block emails, phones, or amounts (the operator
/// wants them accessible for reporting).
const SENSITIVE_COLUMN_PATTERNS = [
  "encrypted_password",
  "password_hash",
  "token_hash",
  "refresh_token",
  "access_token",
  "secret",
  "api_key",
  "service_role",
];

/// Schemas the model must never reach. `public` is the only allowed
/// namespace. Auth schema (users, sessions), storage schema (buckets,
/// objects w/ path metadata), realtime internals, cron, vault, and the
/// pg_* / information_schema catalogs are all off-limits.
const BLOCKED_SCHEMA_PATTERNS = [
  /\bauth\.[A-Za-z_][\w]*\b/i,
  /\bstorage\.[A-Za-z_][\w]*\b/i,
  /\brealtime\.[A-Za-z_][\w]*\b/i,
  /\bcron\.[A-Za-z_][\w]*\b/i,
  /\bpg_[A-Za-z_][\w]*\b/i,
  /\bvault\.[A-Za-z_][\w]*\b/i,
  /\binformation_schema\.[A-Za-z_][\w]*\b/i,
  /\bpg_catalog\b/i,
];

/// Keywords that must not appear anywhere in the query — DML + DDL.
/// The RPC wrapper also structurally rejects these (they can't appear as
/// subqueries in Postgres), but a client-side check gives a friendlier
/// error and avoids a round-trip.
const BANNED_KEYWORDS =
  /\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|COPY|MERGE|CALL|EXECUTE|PREPARE|VACUUM|CLUSTER|REINDEX|LOCK|COMMENT\s+ON|SECURITY\s+DEFINER)\b/i;

/// Strips known-sensitive keys from every row. Preserves everything else
/// so the model can still report emails, phones, amounts, etc.
function stripSensitiveColumns(rows: unknown): unknown {
  if (!Array.isArray(rows)) return rows;
  return rows.map((row) => {
    if (row === null || typeof row !== "object") return row;
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(row as Record<string, unknown>)) {
      const lk = k.toLowerCase();
      if (SENSITIVE_COLUMN_PATTERNS.some((p) => lk.includes(p))) continue;
      out[k] = v;
    }
    return out;
  });
}

async function toolRunReadQuery(
  admin: SupabaseClient,
  args: { sql?: string; description?: string },
): Promise<Record<string, unknown>> {
  const sql = (args.sql ?? "").trim().replace(/;+\s*$/g, "");
  const description = (args.description ?? "").trim();

  if (!sql) {
    return { eroare: "Interogare goală. Trimite un SELECT valid." };
  }
  if (sql.length > 4000) {
    return { eroare: "Interogare prea lungă (>4000 caractere). Simplific-o." };
  }

  // Statement kind check — allow SELECT and WITH ... SELECT only.
  const firstToken = sql.match(/^\s*(\w+)/)?.[1]?.toUpperCase() ?? "";
  if (firstToken !== "SELECT" && firstToken !== "WITH") {
    return {
      eroare:
        "Doar SELECT sau WITH permise. Query-ul tău începe cu " +
        `"${firstToken}".`,
    };
  }

  // Keyword blocklist.
  const bannedMatch = sql.match(BANNED_KEYWORDS);
  if (bannedMatch) {
    return {
      eroare:
        `Cuvântul cheie "${bannedMatch[0]}" nu este permis. ` +
        "run_read_query e strict pentru citire.",
    };
  }

  // Schema whitelist — only public.
  for (const pattern of BLOCKED_SCHEMA_PATTERNS) {
    const m = sql.match(pattern);
    if (m) {
      return {
        eroare:
          `Referință la schema restricționată "${m[0]}" respinsă. ` +
          "Doar schema public este accesibilă.",
      };
    }
  }

  // Auto-append LIMIT 200 if the query has no LIMIT of its own.
  const hasLimit = /\bLIMIT\s+\d+\b/i.test(sql);
  const finalSql = hasLimit ? sql : `${sql} LIMIT 200`;

  // Call the RPC.
  const { data, error } = await admin.rpc("exec_readonly_sql", {
    query: finalSql,
  });
  if (error) {
    return {
      eroare: `RPC eșuat: ${error.message}`,
      sql_incercat: finalSql.slice(0, 300),
    };
  }
  // The RPC returns either jsonb array of rows OR a jsonb object with
  // {eroare, sqlstate} when the wrapped query threw.
  if (data && typeof data === "object" && !Array.isArray(data) && "eroare" in data) {
    return {
      eroare: `Interogare eșuată: ${(data as { eroare?: string }).eroare}`,
      sqlstate: (data as { sqlstate?: string }).sqlstate,
      sql_incercat: finalSql.slice(0, 300),
    };
  }

  const filteredRows = stripSensitiveColumns(data);
  const rowCount = Array.isArray(filteredRows) ? filteredRows.length : 0;

  return {
    description,
    sql_executat: finalSql,
    row_count: rowCount,
    rows: filteredRows,
    nota: rowCount >= 200 && !hasLimit
      ? "Rezultatul a fost tăiat automat la 200 rânduri. Adaugă un LIMIT " +
        "explicit sau rafinează filtrul dacă vrei un set specific."
      : undefined,
  };
}

async function dispatchTool(
  name: string,
  args: Record<string, unknown>,
  admin: SupabaseClient,
): Promise<unknown> {
  const start = Date.now();
  let result: unknown;
  try {
    result = await dispatchToolInner(name, args, admin);
    return result;
  } catch (e) {
    console.error(`[tth_assistant] tool ${name} failed`, e);
    result = { eroare: "Tool-ul a eșuat. Continuă fără aceste date." };
    return result;
  } finally {
    const ms = Date.now() - start;
    const rows = approxRowCount(result);
    // Argument keys only — never values. Keeps logs free of names / emails.
    const keys = Object.keys(args ?? {}).join(",");
    console.log(
      `[tth_assistant] tool=${name} ms=${ms} approx_rows=${rows} arg_keys=${keys}`,
    );
  }
}

async function dispatchToolInner(
  name: string,
  args: Record<string, unknown>,
  admin: SupabaseClient,
): Promise<unknown> {
  try {
    switch (name) {
      case "get_dashboard_summary":
        return await toolGetDashboardSummary(admin);
      case "get_children_summary":
        return await toolGetChildrenSummary(admin, args as { only_active?: boolean });
      case "search_child_by_name":
        return await toolSearchChildByName(admin, args as { query: string });
      case "get_child_details":
        return await toolGetChildDetails(admin, args as { child_name: string });
      case "get_workshops":
        return await toolGetWorkshops(
          admin,
          args as { scope: string; from?: string; to?: string },
        );
      case "get_attendance_summary":
        return await toolGetAttendanceSummary(
          admin,
          args as { days?: number; child_name?: string },
        );
      case "get_payments_due":
        return await toolGetPaymentsDue(admin, args as { only_overdue?: boolean });
      case "get_trainers_summary":
        return await toolGetTrainersSummary(admin);
      case "get_demo_workshops_summary":
        return await toolGetDemoWorkshopsSummary(admin, args as { scope?: string });
      case "get_center_info":
        return toolGetCenterInfo();
      case "get_top_children_attendance":
        return await toolGetTopChildrenAttendance(
          admin,
          args as { days?: number; limit?: number },
        );
      case "get_workshop_attendance_analysis":
        return await toolGetWorkshopAttendanceAnalysis(admin);
      case "get_financial_summary":
        return await toolGetFinancialSummary(admin);
      case "get_risk_children":
        return await toolGetRiskChildren(admin);
      case "get_parent_account_status":
        return await toolGetParentAccountStatus(admin);

      // Overview / dashboard
      case "get_center_overview":
        return await toolGetCenterOverview(admin);
      case "get_today_summary":
        return await toolGetTodaySummary(admin);
      case "get_week_summary":
        return await toolGetWeekSummary(admin);
      case "get_month_summary":
        return await toolGetMonthSummary(admin);
      case "get_important_alerts":
        return await toolGetImportantAlerts(admin);
      case "get_data_quality_issues":
        return await toolGetDataQualityIssues(admin);

      // Children
      case "get_child_profile":
        return await toolGetChildProfile(admin, args as { child_name: string });
      case "get_child_active_workshops":
        return await toolGetChildActiveWorkshops(
          admin,
          args as { child_name: string },
        );
      case "get_child_recent_activity":
        return await toolGetChildRecentActivity(
          admin,
          args as { child_name: string; limit?: number },
        );
      case "get_children_without_active_workshop":
        return await toolGetChildrenWithoutActiveWorkshop(
          admin,
          args as { limit?: number },
        );
      case "get_children_with_multiple_workshops":
        return await toolGetChildrenWithMultipleWorkshops(
          admin,
          args as { limit?: number },
        );
      case "get_children_by_workshop_type":
        return await toolGetChildrenByWorkshopType(
          admin,
          args as { workshop_type: string; limit?: number },
        );
      case "get_new_children_this_month":
        return await toolGetNewChildrenThisMonth(
          admin,
          args as { limit?: number },
        );
      case "get_inactive_children":
        return await toolGetInactiveChildren(
          admin,
          args as { limit?: number },
        );
      case "get_children_birthdays_upcoming":
        return await toolGetChildrenBirthdaysUpcoming(
          admin,
          args as { days?: number; limit?: number },
        );

      // Attendance
      case "get_attendance_by_date":
        return await toolGetAttendanceByDate(admin, args as { date: string });
      case "get_attendance_by_workshop":
        return await toolGetAttendanceByWorkshop(
          admin,
          args as { workshop_title: string; days?: number },
        );
      case "get_attendance_by_trainer":
        return await toolGetAttendanceByTrainer(
          admin,
          args as { trainer_name: string; days?: number },
        );
      case "get_children_with_consecutive_absences":
        return await toolGetChildrenWithConsecutiveAbsences(
          admin,
          args as { min_run?: number; limit?: number },
        );
      case "get_motivated_absences":
        return await toolGetMotivatedAbsences(
          admin,
          args as { days?: number; limit?: number },
        );
      case "compare_attendance_periods":
        return await toolCompareAttendancePeriods(
          admin,
          args as { window_days?: number },
        );

      // Workshops
      case "get_workshops_by_type":
        return await toolGetWorkshopsByType(
          admin,
          args as { workshop_type: string },
        );
      case "get_workshops_by_trainer":
        return await toolGetWorkshopsByTrainer(
          admin,
          args as { trainer_name: string },
        );
      case "get_active_workshop_series":
        return await toolGetActiveWorkshopSeries(
          admin,
          args as { limit?: number },
        );
      case "get_workshop_children":
        return await toolGetWorkshopChildren(
          admin,
          args as { workshop_title: string },
        );
      case "get_most_popular_workshops":
        return await toolGetMostPopularWorkshops(
          admin,
          args as { limit?: number; least?: boolean },
        );
      case "get_workshops_without_children":
        return await toolGetWorkshopsWithoutChildren(admin);
      case "get_workshops_without_trainer":
        return await toolGetWorkshopsWithoutTrainer(admin);
      case "get_workshop_capacity_summary":
        return await toolGetWorkshopCapacitySummary(admin);

      // Trainers
      case "get_trainer_profile":
        return await toolGetTrainerProfile(
          admin,
          args as { trainer_name: string },
        );
      case "get_trainer_workload":
        return await toolGetTrainerWorkload(
          admin,
          args as { days?: number; limit?: number },
        );
      case "get_trainer_week_schedule":
        return await toolGetTrainerWeekSchedule(
          admin,
          args as { trainer_name: string },
        );

      // Parents
      case "search_parent_by_name_or_email":
        return await toolSearchParentByNameOrEmail(
          admin,
          args as { query: string; limit?: number },
        );
      case "get_parent_children":
        return await toolGetParentChildren(
          admin,
          args as { parent_name: string },
        );
      case "get_pending_parent_setups":
        return await toolGetPendingParentSetups(
          admin,
          args as { limit?: number },
        );
      case "get_expired_parent_setups":
        return await toolGetExpiredParentSetups(
          admin,
          args as { limit?: number },
        );

      // Payments
      case "get_payments_by_method":
        return await toolGetPaymentsByMethod(
          admin,
          args as {
            methods?: string[];
            method?: string;
            year?: number;
            month?: number;
            days?: number;
            limit_per_method?: number;
          },
        );
      case "get_advance_paid_cycles":
        return await toolGetAdvancePaidCycles(
          admin,
          args as { limit?: number },
        );
      case "get_cancelled_payment_cycles":
        return await toolGetCancelledPaymentCycles(
          admin,
          args as { limit?: number },
        );
      case "get_payment_cycles_by_child":
        return await toolGetPaymentCyclesByChild(
          admin,
          args as { child_name: string; limit?: number },
        );

      // Notifications
      case "get_notifications_summary":
        return await toolGetNotificationsSummary(admin);
      case "get_recent_notifications":
        return await toolGetRecentNotifications(
          admin,
          args as { limit?: number },
        );

      // Insight composites
      case "get_weekly_action_plan":
        return await toolGetWeeklyActionPlan(admin);
      case "get_growth_opportunities":
        return await toolGetGrowthOpportunities(admin);
      case "get_admin_priority_list":
        return await toolGetAdminPriorityList(admin);

      case "get_free_participants":
        return await toolGetFreeParticipants(
          admin,
          args as { only_active?: boolean; limit?: number },
        );
      case "get_payment_type_summary":
        return await toolGetPaymentTypeSummary(admin);

      // ── Children profile intelligence ───────────────────────────────────
      case "get_children_age_extremes":
        return await toolGetChildrenAgeExtremes(
          admin,
          args as { only_active?: boolean },
        );
      case "get_children_by_last_name":
        return await toolGetChildrenByLastName(
          admin,
          args as { last_name: string },
        );
      case "get_children_missing_profile_data":
        return await toolGetChildrenMissingProfileData(admin);

      // ── Trainer ↔ children relationships ────────────────────────────────
      case "get_children_by_trainer":
        return await toolGetChildrenByTrainer(
          admin,
          args as { trainer_name: string },
        );
      case "get_trainer_children_summary":
        return await toolGetTrainerChildrenSummary(admin);
      case "get_trainers_with_payment_risk":
        return await toolGetTrainersWithPaymentRisk(admin);

      // ── Child progress ─────────────────────────────────────────────────
      case "get_progress_summary":
        return await toolGetProgressSummary(admin);
      case "get_recent_progress_notes":
        return await toolGetRecentProgressNotes(
          admin,
          args as { limit?: number; days?: number },
        );
      case "get_children_by_progress_status":
        return await toolGetChildrenByProgressStatus(
          admin,
          args as { status: "completed" | "in_progress" | "needs_review" },
        );
      case "get_child_progress_details":
        return await toolGetChildProgressDetails(
          admin,
          args as { child_name: string },
        );

      // ── Lesson materials ──────────────────────────────────────────────
      case "get_materials_summary":
        return await toolGetMaterialsSummary(admin);
      case "get_materials_by_workshop_type":
        return await toolGetMaterialsByWorkshopType(
          admin,
          args as { workshop_type: string },
        );
      case "get_recent_materials":
        return await toolGetRecentMaterials(
          admin,
          args as { limit?: number; days?: number },
        );
      case "get_workshops_without_materials":
        return await toolGetWorkshopsWithoutMaterials(admin);

      // ── Payment intelligence ───────────────────────────────────────────
      // Note: get_payment_amount_summary removed on 2026-08-14 — the app
      // doesn't store per-cycle amounts and the tool led to hallucinated
      // sums. Internal composite tools still call the stub function.
      case "get_recent_confirmed_payments":
        return await toolGetRecentConfirmedPayments(
          admin,
          args as { days?: number; limit?: number },
        );
      case "get_children_near_payment_cycle":
        return await toolGetChildrenNearPaymentCycle(admin);

      // ── Workshop attendance / name quality ─────────────────────────────
      case "get_attendance_by_workshop_rankings":
        return await toolGetAttendanceByWorkshopRankings(
          admin,
          args as { days?: number; include_zero_sample?: boolean },
        );
      case "get_workshop_name_quality_issues":
        return await toolGetWorkshopNameQualityIssues(admin);

      // ── Escape hatch — arbitrary SELECT ────────────────────────────────
      case "run_read_query":
        return await toolRunReadQuery(
          admin,
          args as { sql?: string; description?: string },
        );

      default:
        return { eroare: `Tool necunoscut: ${name}` };
    }
  } catch (e) {
    console.error(`[tth_assistant] tool ${name} failed`, e);
    return { eroare: "Tool-ul a eșuat. Continuă fără aceste date." };
  }
}

// ── OpenAI call ─────────────────────────────────────────────────────────────

async function callOpenAi(
  apiKey: string,
  messages: OpenAiMessage[],
): Promise<OpenAiMessage> {
  const body = {
    model: "gpt-4o-mini",
    temperature: 0.2,
    messages,
    tools: TOOLS.map((t) => ({
      type: "function",
      function: {
        name: t.name,
        description: t.description,
        parameters: t.parameters,
      },
    })),
  };
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`OpenAI ${res.status}: ${text.slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    choices?: Array<{ message: OpenAiMessage }>;
  };
  const msg = json.choices?.[0]?.message;
  if (!msg) throw new Error("OpenAI returned no message");
  return msg;
}

// ── Entry point ─────────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed" } as ErrorResponse);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return jsonResponse(401, { error: "Missing Authorization header" });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");

  if (!SUPABASE_URL || !ANON_KEY || !SERVICE_KEY) {
    console.error("Missing Supabase env");
    return jsonResponse(500, { error: "Server misconfigured" });
  }
  if (!OPENAI_API_KEY) {
    console.error("Missing OPENAI_API_KEY");
    return jsonResponse(500, { error: "Asistentul nu este configurat." });
  }

  // 1. JWT verification via user-scoped client.
  const userClient: SupabaseClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const {
    data: { user },
    error: userErr,
  } = await userClient.auth.getUser();
  if (userErr || !user) {
    return jsonResponse(401, { error: "Invalid JWT" });
  }

  // 2. Role gate. Profiles are readable to self via RLS, so the
  //    user-scoped client is fine here.
  const { data: profileRow, error: profileErr } = await userClient
    .from("profiles")
    .select("role")
    .eq("id", user.id)
    .maybeSingle();
  if (profileErr) {
    console.error("profile lookup failed", profileErr);
    return jsonResponse(500, { error: "Profile lookup failed" });
  }
  const role = (profileRow as { role?: string } | null)?.role;
  if (role !== "admin" && role !== "trainer") {
    return jsonResponse(403, {
      error: "Asistentul este disponibil doar pentru administratori și traineri.",
    });
  }

  // 3. Parse body.
  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    return jsonResponse(400, { error: "Invalid JSON body" });
  }
  const body = (raw ?? {}) as { messages?: IncomingMessage[] };
  const incoming = Array.isArray(body.messages) ? body.messages : [];
  if (incoming.length === 0) {
    return jsonResponse(400, { error: "Lista de mesaje este goală." });
  }
  // Reject the last user message if it's absurdly long. Same 4000-char
  // ceiling applies per-message below, but bouncing oversize input early
  // gives a clearer error and avoids OpenAI-side rejections.
  const lastUser = [...incoming].reverse().find((m) => m.role === "user");
  if (lastUser && String(lastUser.content ?? "").length > 4000) {
    return jsonResponse(400, {
      error: "Întrebarea este prea lungă. Reformulează în maxim 4000 de caractere.",
    });
  }
  // Cap history length to keep prompts bounded.
  const trimmed = incoming.slice(-30);

  const openAiMessages: OpenAiMessage[] = [
    { role: "system", content: SYSTEM_PROMPT },
    ...trimmed.map((m) => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: String(m.content ?? "").slice(0, 4000),
    } as OpenAiMessage)),
  ];

  // 4. Admin (service-role) client used by tools to bypass RLS — the
  //    function code itself is the trust boundary.
  const adminClient: SupabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 5. Tool loop. Max 5 rounds — well above realistic depth, low
  //    enough to bound cost on a runaway model. Sources from every
  //    tool the model calls are accumulated into a Set and returned
  //    next to the final reply.
  const sourceSet = new Set<string>();
  try {
    for (let round = 0; round < 5; round += 1) {
      const reply = await callOpenAi(OPENAI_API_KEY, openAiMessages);
      const toolCalls = reply.tool_calls ?? [];
      if (toolCalls.length === 0) {
        const finalText = (reply.content ?? "").trim();
        if (!finalText) {
          return jsonResponse(502, { error: "Răspuns gol de la asistent." });
        }
        return jsonResponse(200, {
          reply: finalText,
          sources: Array.from(sourceSet),
        } as SuccessResponse);
      }
      // Push the assistant turn including tool_calls before the tool
      // responses, per OpenAI's contract.
      openAiMessages.push({
        role: "assistant",
        content: reply.content ?? null,
        tool_calls: toolCalls,
      });
      for (const call of toolCalls) {
        for (const src of sourcesFor(call.function.name)) sourceSet.add(src);
        let args: Record<string, unknown> = {};
        try {
          args = call.function.arguments
            ? (JSON.parse(call.function.arguments) as Record<string, unknown>)
            : {};
        } catch {
          args = {};
        }
        const result = await dispatchTool(call.function.name, args, adminClient);
        openAiMessages.push({
          role: "tool",
          tool_call_id: call.id,
          name: call.function.name,
          content: JSON.stringify(result),
        });
      }
    }
    return jsonResponse(502, {
      error: "Asistentul nu a putut formula un răspuns final.",
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("[tth_assistant] loop failed", msg);
    return jsonResponse(502, {
      error: "Asistentul este temporar indisponibil. Încearcă din nou.",
    });
  }
});

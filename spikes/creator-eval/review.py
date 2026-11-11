"""Writes review.html: an offline page for a person to check every annotated moment and every hard negative by listening/watching.
Usage: python3 -I review.py <dataset-dir>      then open <dataset-dir>/review.html and press "Download validation.json"; save it in the dataset folder.

Each moment plays from 3 s before its start to 3 s after its end (the tolerance used when scoring), with the annotated span shown, and has a
verdict: correct / wrong (not there) / adjust (there, but the times are off; write the corrected start and end). Nothing is uploaded; the page
only reads local files. validate_dataset.py then requires every moment to be marked correct by a person, and a second reviewer on 20 % of queries."""
import html, json, sys
from pathlib import Path

root = Path(sys.argv[1])
items = {i["id"]: i for i in json.loads((root / "items.json").read_text())}
queries = json.loads((root / "queries.json").read_text())
rows = []
for q in queries:
    for n, rel in enumerate(q.get("relevant", [])):
        it = items.get(rel["item"])
        if not it: continue
        tag = "video" if it["kind"] == "video" else "audio" if it["kind"] == "audio" else "img"
        start, end = rel.get("start"), rel.get("end")
        src = html.escape(it["path"]) + (f"#t={max(0, start - 3):.2f},{end + 3:.2f}" if start is not None else "")
        player = (f'<img src="{src}" width="320">' if tag == "img" else f'<{tag} controls preload="metadata" src="{src}" width="320"></{tag}>')
        span = f"{start:.1f}-{end:.1f} s" if start is not None else "whole file"
        rows.append(f'<tr data-q="{html.escape(q["id"])}" data-n="{n}" data-item="{html.escape(rel["item"])}"><td>{html.escape(q["id"])}<br><small>{html.escape(q["feature"])}, {html.escape(q["difficulty"])}</small></td>'
                    f'<td><b>{html.escape(q["text"])}</b><br>annotated: {span} in {html.escape(it["path"])}</td><td>{player}</td>'
                    f'<td><select><option value="">?</option><option>correct</option><option>wrong</option><option>adjust</option></select><br>'
                    f'<input size="5" placeholder="start"> <input size="5" placeholder="end"></td></tr>')
page = f"""<!doctype html><meta charset="utf-8"><title>Creator-media review</title>
<style>body{{font:14px -apple-system,sans-serif;margin:16px}}td{{vertical-align:top;padding:6px;border-bottom:1px solid #8884}}</style>
<h2>Validate annotated moments ({len(rows)})</h2>
<p>Reviewer name: <input id="who"> &nbsp; <button onclick="save()">Download validation.json</button></p><table>{''.join(rows)}</table>
<script>
function save(){{const out=[];document.querySelectorAll('tr[data-q]').forEach(r=>{{const s=r.querySelector('select').value;if(!s)return;const [a,b]=r.querySelectorAll('input');
out.push({{query:r.dataset.q,index:+r.dataset.n,item:r.dataset.item,verdict:s,start:a.value?+a.value:null,end:b.value?+b.value:null,reviewer:document.getElementById('who').value}})}});
const l=document.createElement('a');l.href=URL.createObjectURL(new Blob([JSON.stringify(out,null,1)],{{type:'application/json'}}));l.download='validation.json';l.click()}}
</script>"""
(root / "review.html").write_text(page)
print(f"review.html written with {len(rows)} moments to check")

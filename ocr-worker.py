"""OCR dos PDFs oficiais: renderiza todas as páginas e envia somente texto ao Supabase."""
import json, os, re, subprocess, tempfile, time, urllib.request
from pathlib import Path
ENDPOINT = "https://itobvfemswylcawdydrz.supabase.co/functions/v1/trt16-ocr"
def call(body):
    oidc_url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=trt16-ocr"
    req = urllib.request.Request(oidc_url, headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
    with urllib.request.urlopen(req, timeout=30) as r:
        token = json.load(r)["value"]
    req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.load(r)
def extract(url, directory):
    if not re.fullmatch(r"https://bibliotecadigital\.trt16\.jus\.br/server/api/core/bitstreams/[0-9a-f-]{36}/content", url, re.I):
        raise ValueError("URL oficial inválida")
    pdf = directory / "documento.pdf"
    with urllib.request.urlopen(url, timeout=60) as r, pdf.open("wb") as out:
        size = 0
        while chunk := r.read(1024 * 1024):
            size += len(chunk)
            if size > 100 * 1024 * 1024:
                raise ValueError("PDF acima de 100 MB")
            out.write(chunk)
    subprocess.run(["pdftoppm", "-r", "250", "-png", str(pdf), str(directory / "pagina")], check=True, timeout=300, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pages = sorted(directory.glob("pagina-*.png"), key=lambda p: int(p.stem.split("-")[-1]))
    if not pages:
        raise ValueError("Nenhuma página renderizada")
    texts = []
    for page in pages:
        result = subprocess.run(["tesseract", str(page), "stdout", "-l", "por+eng", "--psm", "3"], check=True, timeout=120, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        texts.append(result.stdout.decode("utf-8"))
        page.unlink()
    return "\n\n".join(texts)
def main():
    processed = 0
    for _ in range(5):
        job = call({"action": "claim"})
        if not job:
            print("Fila OCR sem pendências.")
            break
        try:
            with tempfile.TemporaryDirectory() as d:
                text = extract(job["url"], Path(d))
            if len(text.strip()) < 40:
                raise ValueError("OCR sem texto suficiente")
            saved = call({"action": "save", "id": job["id"], "lease": job["lease"], "text": text})
            if not saved.get("saved"):
                raise RuntimeError("Lease expirado")
            processed += 1
            print(f"PDF {job['id']}: OCR concluído, {len(text)} caracteres.")
        except Exception as exc:
            call({"action": "save", "id": job["id"], "lease": job["lease"], "error": type(exc).__name__ + ": " + str(exc)[:150]})
            print(f"PDF {job['id']}: falha no OCR; nova tentativa agendada.")
    print(f"Total processado: {processed}")
if __name__ == "__main__":
    main()

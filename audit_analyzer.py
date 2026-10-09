import hashlib, re, unicodedata
def normalizar(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c)).lower()
def analisar(texto, cadastro, categoria="original", metodo="texto", hash_pdf=None):
    raw = texto[:6000]
    norm = normalizar(raw)
    cab = norm[:1800]
    inicio = re.search(r"\b(portaria|resolucao(?:\s+administrativa)?)\b", cab)
    m = None
    if inicio and inicio.start()<500:
        header = cab[inicio.start():inicio.start()+250]
        number = re.search(r"\bn[.\s]*[o°]?\s*([0-9]{1,4}(?:\.[0-9]{3})*)\b",header)
        if not number:
            number = re.search(r"^(?:portaria|resolucao(?:\s+administrativa)?)\s+([0-9]{1,4})\b",header)
        if number and number.start()<100:
            after = header[number.end():]
            year = re.match(r"\s*/\s*(20[0-9]{2}|19[0-9]{2})\b",after)
            if not year:
                year = re.match(r"\s*,?\s*de\s+\d{1,2}\s+de\s+[a-z]+\s+de\s+(20[0-9]{2}|19[0-9]{2})\b",after)
            if not year:
                year = re.match(r"\s*,?\s*de\s+\d{1,2}/\d{1,2}/(20[0-9]{2}|19[0-9]{2})\b",after)
            if year:
                m = (inicio.group(1),header[:number.start()],number.group(1),year.group(1))
    base = {"estado":"inconclusivo","documento":None,"evidencia":raw[:1800],"metodo":metodo,"hash_evidencia":hash_pdf or hashlib.sha256(raw.encode()).hexdigest(),"motivo":""}
    if not m:
        base["motivo"]="Cabeçalho com tipo, número e ano não reconhecido de forma inequívoca."
        return base
    tipo = "Portaria" if m[0]=="portaria" else "Resolução"
    numero = int(m[2].replace(".",""))
    ano = int(m[3])
    emissor = None
    if tipo=="Portaria":
        area = m[1]
        if re.search(r"\b(?:dg|diretoria[- ]geral)\b",area):
            emissor="Diretoria-Geral"
        elif re.search(r"\bvp\b|vice[- ]presid",area):
            emissor="Vice-Presidência"
        elif re.search(r"\b(?:gp|gpre)\b|presid",area) or re.search(r"(?:desembargador|desembargadora)\s+presidente",cab):
            emissor="Presidência"
    else:
        if "administrativa" in m[0] or re.search(r"\bra\b",m[1]):
            emissor="Administrativa"
    base["documento"]={"tipo":tipo,"numero":numero,"ano":ano,"emissor":emissor}
    if categoria!="original":
        base["motivo"]="Arquivo compilado ou anexo: identificar o original antes de validar a identidade."
        return base
    if not emissor:
        base["motivo"]="Número e ano candidatos identificados; espécie/emissor insuficientes para validar o tipo."
        return base
    divergencias=[]
    if tipo!=cadastro["tipo"]:
        divergencias.append("tipo")
    if tipo=="Portaria" and emissor!="Presidência":
        divergencias.append("emissor")
    if tipo=="Resolução" and emissor!="Administrativa":
        divergencias.append("espécie")
    if numero!=cadastro["numero"]:
        divergencias.append("número")
    if ano!=cadastro["ano"]:
        divergencias.append("ano")
    base["estado"]="divergente" if divergencias else "conferente_automatico"
    base["motivo"]="Divergência em: "+", ".join(divergencias) if divergencias else "Cabeçalho compatível; conferência automática, sem validação humana."
    return base

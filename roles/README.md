# roles/ — Papéis da máquina

Um **papel** responde "para que serve esta máquina" — não "que CPU ela tem".
Essa separação é o que permite que o mesmo hardware sirva para finalidades
diferentes e que uma família de CPU (ver [`families/`](../families/)) seja
usada por qualquer papel, sem duplicar código de build.

| Papel | Função | Instala | Alvo de referência |
|---|---|---|---|
| `inference` | Servidor de inferência 100% em CPU | deps + llama.cpp compilado + `ai-server.service` + `shell-ia.py` | Xeon E5-2680 v4 (14c/28t, AVX2, 16 GB) |
| `builder` | Compila em Docker, serve registry privado e Gitea | Docker Engine + Compose + registry `localhost:5000` + Gitea | Ryzen 5 3500X (Zen 2, 6c/6t, 64 GB) |

```bash
sudo ./build.sh                      # detecta papel + família e pergunta
sudo ./build.sh --role inference     # força o papel
sudo ./build.sh --dry-run            # simula
```

Quem escolhe o papel é o `detect-hardware.sh` (`choose_role()`), que usa uma
heurística simples e previsível: **Xeon/EPYC → `inference`**; caso contrário,
**≤32 GB de RAM → `inference`, >32 GB → `builder`**. É só uma sugestão — o papel
é sempre uma decisão de uso, e `--role` manda.

## Regra de fronteira

- **Papel** = software, serviços, portas, volumes.
- **Família** = `-march`, ISA, verificação de AVX-512.

O build do llama.cpp é **compartilhado** (`llama-build.sh` na raiz do repositório)
justamente para que essa fronteira não vaze: os dois papéis compilam o mesmo
binário para a mesma família, mudando só o que fazem com ele.

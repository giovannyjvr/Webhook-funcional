# Payment Webhook Service — Haskell

Projeto da disciplina **Programação Funcional** (Aula 24 — Insper 2025-1).

Serviço HTTP de webhook para processamento de pagamentos, implementado em
**Haskell** — linguagem puramente funcional.

---

## Princípios Funcionais Aplicados

| Princípio | Onde no código |
|---|---|
| **Tipos algébricos (ADTs)** | `ValidationResult`, `WebhookPayload`, `Context` — o tipo *força* o tratamento de todos os casos |
| **Funções puras** | Todos os `validate*` — sem IO, sem estado, sem efeitos colaterais |
| **Pipeline com `foldr`** | `runPipeline` compõe validadores com short-circuit |
| **Imutabilidade** | `Context` é imutável; estado compartilhado usa `STM TVar` (transacional) |
| **Separação de efeitos** | Apenas `confirmTransaction` e `cancelTransaction` vivem em `IO` |
| **Pattern matching** | Toda tomada de decisão usa pattern matching, sem `if/else` |

---

## Pré-requisitos

- [GHCup](https://www.haskell.org/ghcup/) — instala GHC e Cabal

```bash
# Instala GHCup (Linux/macOS)
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

# Após instalar, garanta que GHC e Cabal estão disponíveis:
ghc --version    # >= 9.4
cabal --version  # >= 3.8
```

No **Windows**, baixe o instalador em https://www.haskell.org/ghcup/

---

## Instalação e Build

```bash
# 1. Clone o repositório
git clone <URL_DO_REPO>
cd webhook_haskell

# 2. Baixa dependências e compila
cabal build

# Primeira compilação demora ~3-5 minutos (baixa as libs)
```

---

## Como Rodar

### Terminal 1 — sobe o servidor webhook (porta 5000)

```bash
cabal run webhook
```

### Terminal 2 — executa os testes do professor

```bash
# Instale as dependências do script de teste (apenas uma vez)
pip install fastapi uvicorn requests

python test_webhook.py
```

Resultado esperado:
```
1. Webhook test "Token Inválido": ok
2. Webhook test "Payload Vazio": ok
3. Webhook test "Campos Ausentes": ok
4. Webhook test "Fluxo Correto": ok
5. Webhook test "Transação Duplicada": ok
6. Webhook test "Amount Incorreto": ok
6/6 tests completed.
```

---

## Estrutura do Projeto

```
webhook_haskell/
├── src/
│   └── Main.hs          # Toda a lógica do servidor
├── webhook.cabal        # Definição do projeto e dependências
├── test_webhook.py      # Suite de testes do professor (não modificado)
└── README.md
```

---

## Pipeline de Validação

```
POST /webhook
      │
      ▼
 extractToken + parseBody  ← IO (leitura)
      │
      ▼
 runPipeline preValidators  ← puro (foldr)
  ├─ validateToken
  ├─ validatePayload
  └─ validateRequiredFields
      │
   falhou? ──► 403/400 (sem cancelamento)
      │
      ▼
 runPipeline postValidators  ← puro (foldr)
  ├─ validateNotDuplicate
  └─ validateOrderValues
      │
   falhou? ──► cancelTransaction (IO) + 400
      │
      ▼
 confirmTransaction (IO) + 200
```

---

## Tipos Algébricos

```haskell
data ValidationResult
  = Valid                          -- passou, continua
  | InvalidNoCancel Status Text    -- falhou, não cancela
  | InvalidCancel   Status Text    -- falhou, deve cancelar
```

O compilador Haskell garante que **todos os casos são tratados** — se
esquecer um, o código não compila.

# Recipient management

## Cíl

V aplikaci spravovat, kdo může číst SOPS YAML: zařízení uživatele, servery a
kolegové. Uživatel vidí lidský název, typ a veřejný age klíč; private identity
nikdy do tohoto flow nevstupuje.

## Projektová data

`.sops-gui/recipients.json` je verzovaný, neobsahuje secrety a drží:

- `id` (UUID), `label`, `kind` (`device`, `server`, `person`), `ageRecipient`;
- volitelnou poznámku.

Duplicita public key je odmítnuta. Registry je pouze adresář kontaktů;
`.sops.yaml` je jediná autorita pro creation rules a skutečný access souboru je
SOPS metadata v tom souboru.

**Odloženo do dalšího milníku: editor registry uvnitř aplikace.** V této verzi
je registry *jen čtený* — oba Access panely z něj berou `label` a `kind`, ale
záznam vytvoří jen ruční editace `.sops-gui/recipients.json`. `RecipientRegistry
.save/upsert/remove` proto zatím nemá produkčního volajícího (jen testy); není
to opomenutí a API se nemá mazat. Žádný plan task editor nespecifikoval a
přidávat ho mimo plán by znamenalo navrhovat UI bez zadání. Recipient, o kterém
registry neví, se nikdy neskrývá — zobrazí se svým `age1…` klíčem.

## Operace

U otevřeného YAML panel Access zobrazí aktuální age recipients z metadata a
jejich registry labels. Add/remove připraví změnu, ale nic nezapisuje.

`Apply to file` provede explicitní updatekeys: existující private identity
odšifruje data key, bridge nahradí key groups, data key zabalí pro nový age set
a `AtomicFileWriter` atomicky zapíše výsledek. Hodnoty YAML se nemění.

`Apply to project` nejdřív aktualizuje odpovídající creation rule v
`.sops.yaml`, poté nabídne nalezené SOPS YAML soubory. Každý soubor se zpracuje
samostatně; UI ukáže progress a konkrétní failures. Konfigurace se nezapisuje,
pokud uživatel nepotvrdí finální dialog se souhrnem add/remove a počtem souborů.

Odebrání posledního recipienta je vždy odmítnuto. Odebrání recipienta z file
nebo projektu vyžaduje destructive confirmation včetně počtu dotčených souborů.

## Bridge a bezpečnost

Nové bridge API je in-memory varianta SOPS `updatekeys`: načte encrypted YAML,
vezme data key jen přes explicitně předanou session identity, nahradí metadata
key groups a zavolá `UpdateMasterKeysWithKeyServices`. Nevolá CLI, environment,
key files ani age plugins. Chyby nesmí nést YAML hodnoty ani private key.

V1 podporuje jen nativní `age1...` X25519 recipients; config s jinými backendy
je read-only s jasným vysvětlením. Soubory a config se před zápisem kontrolují
na second-writer fingerprint.

## Testování

- bridge: přidání/odebrání recipienta mění decryptability přesně podle setu;
- bridge: invalid/private/plugin recipient je odmítnut bez leakage;
- registry: labels, duplicity a persistence;
- file apply: atomický zápis, soubor zůstane čitelný novým recipientem;
- project apply: partial failures, cancellation a config/file consistency;
- UI: confirmation, progress a registry label u unknown key fallbacku.

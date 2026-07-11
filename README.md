# espanso Web UI

Espanso için Nim + Prologue ile yazılmış hafif web arayüzü.

İnsanlar YAML config ile uğraşmadan, tarayıcıdan espanso match'lerini ve ayarlarını yönetebilir.

---

## Nedir?

Espanso harika bir metin genişletici (text expander). Ama ayar dosyaları YAML ile yönetiliyor. Bu araç, YAML bilgisi olmadan da espanso'yu kullanmanı sağlar.

- Tetikleyici (trigger) + genişletme (replacement) yaz → kaydet
- Match dosyalarını listele / oluştur / düzenle
- Config dosyalarını (varsayılan + uygulama bazlı) düzenle
- İleri seviye kullanıcılar için YAML editörü
- Tek tıkla espanso yeniden başlat
- Mevcut match'lerde arama

---

## Özellikler

| Özellik | Açıklama |
|---------|----------|
| **Hızlı match ekleme** | Form ile trigger + replacement gir, hedef dosyayı seç, kaydet |
| **Çok satırlı replacement** | Otomatik YAML literal block (`\|`) syntax'ına çevirir |
| **word / propagate_case / uppercase_style** | Form ile bu ayarlar yapılabilir |
| **Match silme** | Trigger'a göre, onay kutusu ile |
| **YAML editörü** | Tüm dosyayı ham YAML olarak düzenle (kompleks match'ler, değişkenler, formlar için) |
| **YAML doğrulama** | Kaydetmeden önce NimYAML ile sözdizimi kontrolü |
| **Config dosyaları** | `default.yml` + uygulama bazlı config'ler (`config/vscode.yml` vb.) |
| **Espanso yeniden başlat** | Tek tıkla `espanso restart` |
| **Otomatik durum kontrolü** | 30 saniyede bir arka plan süreci çalışıyor mu kontrol eder |
| **Koyu tema** | Göz yormayan modern arayüz |
| **Responsive** | Mobil dahil tüm ekranlarda çalışır |

---

## Gereksinimler

- **Nim ≥ 2.2.0** (test edildi: 2.2.10)
- **Nimble** (Nim ile birlikte gelir)
- **espanso v2.x** yüklü olmalı (PATH'de erişilebilir)
- Linux / macOS / Windows (WSL)

---

## Kurulum

### 1. Kaynak kodu indir

```bash
git clone https://github.com/ranonimolan-wq/espanso-webui
cd espanso-webui
```

### 2. Bağımlılıkları yükle

```bash
nimble install -y
```

### 3. Derle

```bash
nim c -d:release --threads:off --outdir=build src/espanso_webui.nim
```

Veya nimble task ile:

```bash
nimble run
```

---

## Çalıştırma

### Doğrudan çalıştırma

```bash
./build/espanso_webui
# Varsayılan: http://127.0.0.1:7777, 2 thread
```

Özel port/host/thread ile:

```bash
./build/espanso_webui --host=0.0.0.0 --port=8080 --threads=4
```

Tarayıcıda aç: http://127.0.0.1:7777

---

## Kullanım

### Match ekleme

1. **Match'ler** sekmesine geç
2. Trigger alanına `:hello` yaz
3. Replacement alanına `Merhaba dünya!` yaz
4. Hedef dosya seç (örneğin `base.yml`)
5. İstersen `word: true` veya `propagate_case: true` işaretle
6. **+ Ekle** butonuna bas

Espanso `auto_restart: true` (varsayılan) olduğu için dosya değişince otomatik yeniden yükler.

### Çok satırlı replacement

```
Trigger: :div
Replacement:
<div>
  $|$
</div>
```

Web UI otomatik olarak YAML literal block syntax'ına çevirir:

```yaml
matches:
  - trigger: ":div"
    replace: |
      <div>
        $|$
      </div>
```

### Kompleks match (değişkenler, formlar, regex)

**YAML Editör** sekmesini kullan. Tüm dosyayı ham YAML olarak düzenleyebilirsin.

Örnek — tarih değişkeni:

```yaml
matches:
  - trigger: ":now"
    replace: "Saat: {{mytime}}"
    vars:
      - name: mytime
        type: date
        params:
          format: "%H:%M:%S"
```

### Uygulama bazlı config

**Config** sekmesinde **+ Yeni App Config** butonu ile. Örnek: VS Code'da farklı backend kullan:

```yaml
# config/vscode.yml
filter_exec: "Visual Studio Code"
backend: inject
inject_delay: 5
```

### Match silme

Match'ler sekmesindeki listede her match'in yanında **Sil** butonu var. Onay kutusu ile silinir.

---

## API Endpoint'leri

Tüm endpoint'ler JSON döner. POST/PUT gövdeleri `application/json`.

| Method | Path | Açıklama |
|--------|------|----------|
| GET  | `/api/status` | Espanso durumu (kurulu mu, çalışıyor mu, config dizini, dosya sayıları) |
| POST | `/api/restart` | `espanso restart` çağırır |
| POST | `/api/toggle` | `enable: true/false` gövdesi ile etkinleştir/devre dışı bırak |
| GET  | `/api/match-files` | Tüm match dosyalarını listele (ham YAML dahil) |
| POST | `/api/match-files` | Yeni match dosyası oluştur (`{name, rawYaml?}`) |
| POST | `/api/match-files/update` | Match dosyasını güncelle (`{name, rawYaml}`) |
| GET  | `/api/matches` | Tüm dosyaların özeti |
| POST | `/api/matches` | Basit match ekle (`{trigger, replace, file, word?, propagateCase?, uppercaseStyle?}`) |
| POST | `/api/matches/delete` | Match sil (`{trigger, file}`) |
| GET  | `/api/config-files` | Config dosyalarını listele |
| POST | `/api/config-files` | Yeni config dosyası oluştur |
| POST | `/api/config-files/update` | Config dosyasını güncelle (`{name, rawYaml}`) |

---

## Mimari

```
espanso-webui/
├── espanso_webui.nimble     # Nimble paketi
├── src/
│   ├── espanso_webui.nim    # Giriş noktası + statik dosya sunumu
│   ├── types.nim            # SimpleMatch, MatchFile, AppConfigFile, EspansoStatus
│   ├── espanso_cli.nim      # espanso CLI sarmalayıcı (execCmdEx)
│   ├── yaml_store.nim       # YAML oku/yaz/doğrula + match ekle/sil
│   └── routes.nim           # Tüm HTTP işleyicileri
└── public/                  # Ön yüz (vanilla JS, derleme yok)
    ├── index.html           # Tek sayfa arayüz
    ├── style.css            # Modern koyu tema
    └── app.js               # Tüm ön yüz mantığı (~750 satır)
```

### Tasarım kararları

1. **Ham YAML yaklaşımı**: Espanso'nun tüm YAML şemasını (form_fields, vars, regex, image_path, ...) Nim tipine eşlemek yerine, dosyaları ham metin olarak saklarız. Sadece match ekleme/silme için hafif ayrıştırıcı kullanırız. Bu, daha az kod + daha az hata demek.

2. **POST-only mutations**: Prologue PUT/DELETE method'larında bazı kararlılık sorunları olduğu için tüm değişiklikler POST ile. Bu REST prensiplerinden feragat etmek ama çalışmak daha önemli.

3. **`--threads:off`**: Prologue çoklu iş parçacığı + ORC + NimYAML karışımı çalışma zamanında çökme yapabiliyor. Tek iş parçacığı daha kararlı. Bu arayüz için yeterli.

4. **`{.cast(gcsafe).}`**: NimYAML GC-safe değil. Async işleyicilerden çağırırken `cast(gcsafe)` bloğu kullanıyoruz. Risk: Nim ORC tek iş parçacığı olduğu için çalışma zamanında sorun yaratmıyor.

5. **Statik dosyalar tek tek route'a ekli**: Prologue route pattern'da regex parametre sözdizimi sorunlu olduğu için `/index.html`, `/style.css`, `/app.js` ayrı route'lar.

---

## Sınırlamalar

- **Match silme trigger'a göre**: Aynı trigger birden fazla dosyada varsa, sadece belirttiğin dosyadaki silinir. Aynı dosyada birden fazla aynı trigger varsa, ilki silinir.
- **App config şablonu minimal**: Yeni app config oluşturunca sadece `filter_exec`, `backend` alanları eklenir. Diğer alanları YAML editörden ekleyebilirsin.
- **Espanso path lookup çalışma zamanında**: Her status çağrısında `espanso path config` çalışır. Çok sık çağırma (arayüz 30 saniyede bir yapıyor).
- **Wayland app-specific config desteklenmez**: espanso kendisi Wayland'de uygulama bazlı config desteklemiyor (arayüz bunu engellemez ama espanso görmezden gelir).

---

## Geliştirme

### Debug build (stack trace ile)

```bash
nim c -d:debug --threads:off --stacktrace --lineTrace --outdir=build/debug src/espanso_webui.nim
./build/debug/espanso_webui
```

### Ön yüz değişikliği

Ön yüz vanilla JS, derleme gerekmez. `public/` altındaki dosyaları düzenle, tarayıcıyı yenile.

### Yeni API endpoint ekleme

1. `routes.nim`'de işleyici yaz: `proc myHandler*(ctx: Context) {.async, gcsafe.} =`
2. `registerRoutes`'a ekle: `app.post("/api/my-endpoint", myHandler)`
3. Ön yüzde `API.myEndpoint = '/api/my-endpoint'` ekle

---

## Sorun giderme

### "espanso yüklü değil veya config dizini bulunamadı"

- `espanso --version` çalışıyor mu? PATH'de olmayabilir.
- `espanso path config` çıktısı ne dönüyor? Boşsa espanso kurulmamış.

### "Espanso daemon çalışmıyor"

- `espanso start` çalıştır.
- `espanso service status` ile servis durumunu kontrol et.
- Linux'ta: `systemctl --user status espanso`

### Match ekliyorum ama espanso görmüyor

- `espanso restart` çağır (arayüzdeki yeniden başlat butonu)
- `espanso match list` ile yüklü match'leri kontrol et
- `espanso log` ile logları kontrol et (YAML sözdizimi hatası varsa görünür)

### Arayüz açılıyor ama sayfa boş

- Tarayıcı konsoluna bakın (F12)
- `/api/status` endpoint'ini manuel çağırın: `curl http://127.0.0.1:7777/api/status`

---

## Lisans

MIT

---

## Katkıda bulunma

PR'ler welcome. Özellikle şu konularda:

- [ ] Match drag-drop yeniden sıralama
- [ ] Match kategorileri (etiket sistemi)
- [ ] Espanso package install/uninstall arayüzü
- [ ] Match export/import (JSON)
- [ ] Karax veya htmx ile ön yüz yeniden yazım
- [ ] i18n (Türkçe + İngilizce)

---

## Teknoloji

| Bileşen | Sürüm |
|---------|-------|
| Nim | 2.2.10 |
| Prologue | 0.6.8 |
| NimYAML | 2.2.1 |
| Ön yüz | Vanilla HTML/CSS/JS |
| Binary boyutu | ~3 MB |
| Bellek kullanımı | ~10 MB |

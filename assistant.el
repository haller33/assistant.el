;;; assistant.el --- LFM 2.5 Audio TTS via HTTP API (streaming) -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Seu Nome

;; Author: Seu Nome <voce@exemplo.com>
;; Version: 1.0.0
;; Package-Requires: ((emacs "28.1") (transient "0.4") (seq "2.24"))
;; Keywords: multimedia, tts, speech

;;; Commentary:
;; Cliente Emacs para o servidor LFM 2.5 Audio (llama-liquid-audio-server).
;; Envia texto selecionado, parágrafo ou buffer para a API de chat completions
;; e reproduz o áudio gerado em streaming.
;;
;; Uso:
;;   M-x assistant-mode               (ativa o modo global)
;;   C-c t s                          falar região
;;   C-c t p                          falar parágrafo
;;   C-c t l                          falar linha
;;   C-c t b                          falar buffer todo
;;   C-c t a                          reproduzir último áudio
;;   C-c t m                          menu transient

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'seq)
(require 'transient)
(eval-when-compile (require 'subr-x))

;; ----------------------------------------------------------------------
;; Grupo de customização
;; ----------------------------------------------------------------------

(defgroup assistant nil
  "Text-to-Speech via LFM 2.5 Audio API (servidor HTTP)."
  :group 'multimedia
  :prefix "assistant-")

(defcustom assistant-api-url "http://localhost:8080"
  "URL base do servidor LFM Audio."
  :type 'string
  :group 'assistant)

(defcustom assistant-model "LFM2.5-Audio-1.5B-Q4_0"
  "Nome do modelo usado na API."
  :type 'string
  :group 'assistant)

(defcustom assistant-temperature 0.0
  "Temperatura para geração (0.0 = determinístico)."
  :type 'float
  :group 'assistant)

(defcustom assistant-system-prompt "Perform TTS. Use the US female voice."
  "Prompt de sistema enviado na requisição."
  :type 'string
  :group 'assistant)

(defcustom assistant-sample-rate 24000
  "Taxa de amostragem esperada do áudio (Hz)."
  :type 'integer
  :group 'assistant)

(defcustom assistant-output-file
  (expand-file-name "assistant-output.wav" temporary-file-directory)
  "Arquivo WAV de saída gerado a partir dos chunks PCM."
  :type 'file
  :group 'assistant)

(defcustom assistant-playback-command nil
  "Comando externo para tocar WAV.
Se nil, tenta detectar automaticamente (ffplay, aplay, play) ou usa Emacs."
  :type '(choice (const :tag "Auto-detectar" nil)
                 (string :tag "Comando customizado"))
  :group 'assistant)

(defcustom assistant-notify-on-finish t
  "Mostrar mensagem quando a geração terminar."
  :type 'boolean
  :group 'assistant)

(defcustom assistant-keep-output nil
  "Se não-nil, não apaga o arquivo WAV após tocar."
  :type 'boolean
  :group 'assistant)

(defcustom assistant-mode-line-format " A"
  "String exibida no mode-line durante geração."
  :type 'string
  :group 'assistant)

(defcustom assistant-server-binary "/home/synbian/rbin/llama-liquid-audio-server"
  "Caminho para o binário do servidor (usado por `assistant-server-start')."
  :type 'file
  :group 'assistant)

(defcustom assistant-ckpt-dir "/home/synbian/git/wget/AI/Models/LFM"
  "Diretório com os arquivos do modelo."
  :type 'directory
  :group 'assistant)

(defcustom assistant-model-file "LFM2.5-Audio-1.5B-Q4_0.gguf"
  "Arquivo principal do modelo."
  :type 'string
  :group 'assistant)

(defcustom assistant-mmproj-file "mmproj-LFM2.5-Audio-1.5B-Q4_0.gguf"
  "Arquivo do projetor multimodal."
  :type 'string
  :group 'assistant)

(defcustom assistant-vocoder-file "vocoder-LFM2.5-Audio-1.5B-Q4_0.gguf"
  "Arquivo do vocoder."
  :type 'string
  :group 'assistant)

(defcustom assistant-tokenizer-file "tokenizer-LFM2.5-Audio-1.5B-Q4_0.gguf"
  "Arquivo do tokenizador de speaker."
  :type 'string
  :group 'assistant)

(defcustom assistant-use-steam-run nil
  "Prefixa o comando do servidor com `steam-run'."
  :type 'boolean
  :group 'assistant)

(defcustom assistant-extra-server-args ""
  "Argumentos extras para o binário do servidor."
  :type 'string
  :group 'assistant)

;; ----------------------------------------------------------------------
;; Estado interno
;; ----------------------------------------------------------------------

(defvar assistant--active-process nil)
(defvar assistant--audio-buffer "")
(defvar assistant--last-output-file nil)
(defvar assistant--mode-line-string "")
(defvar assistant--response-buffer nil)
(defvar assistant--chunks-received 0)
(defvar assistant--headers-skipped nil)  ;; flag para saber se já pulamos cabeçalho

;; ----------------------------------------------------------------------
;; Funções auxiliares
;; ----------------------------------------------------------------------

(defun assistant--expand-model-path (file)
  "Expande FILE relativo a `assistant-ckpt-dir'."
  (expand-file-name file assistant-ckpt-dir))

(defun assistant--detect-player ()
  "Retorna lista de comando para tocar WAV, ou nil para fallback."
  (if assistant-playback-command
      (split-string assistant-playback-command)
    (cond ((executable-find "ffplay")
           '("ffplay" "-nodisp" "-autoexit" "-loglevel" "quiet"))
          ((executable-find "aplay")
           '("aplay" "-q"))
          ((executable-find "play")
           '("play" "-q"))
          (t nil))))

(defun assistant--play-file (file)
  "Reproduz arquivo FILE com player externo ou Emacs."
  (let ((player (assistant--detect-player)))
    (if player
        (apply #'start-process "assistant-play" nil player file)
      (condition-case nil
          (play-sound `(sound :file ,file))
        (error (message "Não foi possível tocar áudio; instale ffplay, aplay ou sox."))))))

(defun assistant--pcm-to-wav (pcm-bytes out-file &optional sample-rate channels bits)
  "Escreve PCM-BYTES (16-bit little-endian) em OUT-FILE com cabeçalho WAV."
  (let ((sample-rate (or sample-rate assistant-sample-rate))
        (channels (or channels 1))
        (bits (or bits 16))
        (data-size (length pcm-bytes)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      ;; RIFF header
      (insert "RIFF")
      (insert (bindat-pack 'u32 (+ 36 data-size)))
      (insert "WAVE")
      ;; fmt subchunk
      (insert "fmt ")
      (insert (bindat-pack 'u32 16))           ; subchunk size (PCM)
      (insert (bindat-pack 'u16 1))            ; audio format (1 = PCM)
      (insert (bindat-pack 'u16 channels))
      (insert (bindat-pack 'u32 sample-rate))
      (insert (bindat-pack 'u32 (* sample-rate channels (/ bits 8)))) ; byte rate
      (insert (bindat-pack 'u16 (* channels (/ bits 8)))) ; block align
      (insert (bindat-pack 'u16 bits))
      ;; data subchunk
      (insert "data")
      (insert (bindat-pack 'u32 data-size))
      (insert pcm-bytes)
      (write-region (point-min) (point-max) out-file nil 'silent))))

;; ----------------------------------------------------------------------
;; Streaming e decodificação SSE
;; ----------------------------------------------------------------------

(defun assistant--process-chunk (chunk-text)
  "Processa uma linha de dados SSE e retorna bytes PCM decodificados."
  (when (string-match "^data: \\(.*\\)" chunk-text)
    (let* ((json-str (match-string 1 chunk-text))
           (json-obj (ignore-errors (json-parse-string json-str :object-type 'alist))))
      (when json-obj
        (let ((choices (cdr (assq 'choices json-obj)))
              (delta (cdr (assq 'delta (elt choices 0))))
              (audio (cdr (assq 'audio_chunk delta))))
          (when audio
            (let ((data (cdr (assq 'data audio))))
              (when data
                (cl-incf assistant--chunks-received)
                (message "Recebido chunk #%d (base64 length: %d)"
                         assistant--chunks-received (length data))
                (base64-decode-string data t)))))))))

(defun assistant--filter (proc string)
  "Filtro para processar dados recebidos do servidor."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))

      ;; Pular cabeçalhos HTTP se ainda não foram ignorados
      (unless assistant--headers-skipped
        (when (re-search-forward "\r\n\r\n" nil t)
          (delete-region (point-min) (point))
          (setq assistant--headers-skipped t)
          (message "Cabeçalhos HTTP ignorados, iniciando leitura SSE...")))

      ;; Processar eventos SSE (separados por "\n\n")
      (while (search-forward "\n\n" nil t)
        (let ((chunk (buffer-substring (point-min) (point))))
          (delete-region (point-min) (point))
          (let ((pcm-bytes (assistant--process-chunk chunk)))
            (when pcm-bytes
              (setq assistant--audio-buffer
                    (concat assistant--audio-buffer pcm-bytes)))))))))

(defun assistant--sentinel (proc event)
  "Sentinel executado ao final da conexão."
  (when (memq (process-status proc) '(exit signal))
    (setq assistant--active-process nil)
    (setq assistant--mode-line-string "")
    (force-mode-line-update t)
    (let ((text (process-get proc 'assistant-text)))
      (message "Conexão encerrada. Chunks recebidos: %d, tamanho total PCM: %d bytes"
               assistant--chunks-received (length assistant--audio-buffer))
      (cond ((and (eq (process-exit-status proc) 0)
                  (> (length assistant--audio-buffer) 0))
             ;; Salvar PCM bruto para depuração
             (let ((raw-file (concat temporary-file-directory "assistant-raw.pcm")))
               (with-temp-file raw-file
                 (set-buffer-multibyte nil)
                 (insert assistant--audio-buffer))
               (message "PCM bruto salvo em %s" raw-file))
             ;; Converter para WAV
             (assistant--pcm-to-wav assistant--audio-buffer assistant-output-file)
             (setq assistant--last-output-file assistant-output-file)
             (when assistant-notify-on-finish
               (message "TTS concluído: %s" assistant-output-file))
             (assistant--play-file assistant-output-file)
             (unless assistant-keep-output
               (run-with-timer 10 nil (lambda (f) (ignore-errors (delete-file f)))
                               assistant-output-file))
             (run-hook-with-args 'assistant-after-finish-hook text))
            (t
             (message "Falha na geração TTS ou áudio vazio")
             (when (buffer-live-p assistant--response-buffer)
               (display-buffer assistant--response-buffer)))))
    ;; Resetar estado
    (setq assistant--audio-buffer "")
    (setq assistant--chunks-received 0)
    (setq assistant--headers-skipped nil)
    (when (buffer-live-p assistant--response-buffer)
      (kill-buffer assistant--response-buffer))))

;; ----------------------------------------------------------------------
;; Requisição HTTP / SSE
;; ----------------------------------------------------------------------

(defun assistant--request-tts (text)
  "Inicia requisição SSE para gerar TTS."
  (let* ((url (concat assistant-api-url "/v1/chat/completions"))
         (parsed (url-generic-parse-url url))
         (host (url-host parsed))
         (port (or (url-port parsed) 80))
         (path (url-filename parsed))
         (url-request-data
          (json-serialize
           `((model . ,assistant-model)
             (temperature . ,assistant-temperature)
             (stream . t)
             (messages . [((role . "system") (content . ,assistant-system-prompt))
                          ((role . "user") (content . ,text))]))))
         (request (format "POST %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
                          path host port (length url-request-data) url-request-data)))
    ;; Criar processo de rede
    (let ((proc (open-network-stream "assistant-tts"
                                     (generate-new-buffer " *assistant-http*")
                                     host port
                                     :type 'plain
                                     :filter #'assistant--filter
                                     :sentinel #'assistant--sentinel)))
      (setq assistant--response-buffer (process-buffer proc))
      (setq assistant--audio-buffer "")
      (setq assistant--chunks-received 0)
      (setq assistant--headers-skipped nil)
      (process-put proc 'assistant-text text)
      (process-send-string proc request)
      (setq assistant--active-process proc)
      (setq assistant--mode-line-string assistant-mode-line-format)
      (force-mode-line-update t)
      (message "Requisição enviada para %s:%d..." host port))))

;; ----------------------------------------------------------------------
;; Comandos interativos
;; ----------------------------------------------------------------------

;;;###autoload
(defun assistant-speak-region (start end)
  "Falar região selecionada."
  (interactive "r")
  (if (use-region-p)
      (assistant--request-tts (buffer-substring-no-properties start end))
    (user-error "Nenhuma região ativa")))

;;;###autoload
(defun assistant-speak-paragraph ()
  "Falar parágrafo atual."
  (interactive)
  (let ((bounds (if (derived-mode-p 'org-mode)
                    (bounds-of-thing-at-point 'paragraph)
                  (save-excursion
                    (mark-paragraph)
                    (cons (region-beginning) (region-end))))))
    (if bounds
        (assistant--request-tts (buffer-substring-no-properties (car bounds) (cdr bounds)))
      (user-error "Parágrafo não encontrado"))))

;;;###autoload
(defun assistant-speak-line ()
  "Falar linha atual."
  (interactive)
  (let ((line (buffer-substring-no-properties
               (line-beginning-position)
               (line-end-position))))
    (if (string-empty-p line)
        (user-error "Linha vazia")
      (assistant--request-tts line))))

;;;###autoload
(defun assistant-speak-buffer ()
  "Falar buffer inteiro."
  (interactive)
  (assistant--request-tts (buffer-substring-no-properties (point-min) (point-max))))

;;;###autoload
(defun assistant-play-last ()
  "Reproduzir último áudio gerado."
  (interactive)
  (if (and assistant--last-output-file (file-exists-p assistant--last-output-file))
      (assistant--play-file assistant--last-output-file)
    (user-error "Nenhum áudio anterior disponível")))

;;;###autoload
(defun assistant-cancel ()
  "Cancelar geração em andamento."
  (interactive)
  (if assistant--active-process
      (progn
        (delete-process assistant--active-process)
        (setq assistant--active-process nil)
        (setq assistant--mode-line-string "")
        (force-mode-line-update t)
        (message "Geração cancelada"))
    (message "Nenhuma geração ativa")))

;;;###autoload
(defun assistant-server-start ()
  "Iniciar servidor LFM Audio em segundo plano."
  (interactive)
  (unless (file-executable-p assistant-server-binary)
    (user-error "Binário do servidor não executável: %s" assistant-server-binary))
  (let ((cmd `(,assistant-server-binary
               "-m" ,(assistant--expand-model-path assistant-model-file)
               "-mm" ,(assistant--expand-model-path assistant-mmproj-file)
               "-mv" ,(assistant--expand-model-path assistant-vocoder-file)
               "--tts-speaker-file" ,(assistant--expand-model-path assistant-tokenizer-file)
               ,@(when assistant-use-steam-run '("steam-run"))
               ,@(split-string assistant-extra-server-args))))
    (apply #'start-process "assistant-server" "*assistant-server*" cmd)
    (message "Servidor LFM Audio iniciado (buffer *assistant-server*)")))

;;;###autoload
(defun assistant-check-health ()
  "Verificar saúde da API (endpoint /health)."
  (interactive)
  (url-retrieve (concat assistant-api-url "/health")
                (lambda (status)
                  (if (plist-get status :error)
                      (message "API não responde: %s" (plist-get status :error))
                    (with-current-buffer (current-buffer)
                      (goto-char (point-min))
                      (re-search-forward "\n\n" nil t)
                      (let ((json (ignore-errors (json-read))))
                        (message "API: %s, modelo: %s"
                                 (cdr (assq 'status json))
                                 (cdr (assq 'model json))))))
                  (kill-buffer))
                nil t))

;; ----------------------------------------------------------------------
;; Geração de WAV (usando bindat)
;; ----------------------------------------------------------------------

(defun assistant--pcm-to-wav (pcm-bytes out-file &optional sample-rate channels bits)
  "Escreve PCM-BYTES (16-bit little-endian) em OUT-FILE com cabeçalho WAV."
  (let ((sample-rate (or sample-rate assistant-sample-rate))
        (channels (or channels 1))
        (bits (or bits 16))
        (data-size (length pcm-bytes)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      ;; RIFF header
      (insert "RIFF")
      (insert (bindat-pack 'u32 (+ 36 data-size)))
      (insert "WAVE")
      ;; fmt subchunk
      (insert "fmt ")
      (insert (bindat-pack 'u32 16))
      (insert (bindat-pack 'u16 1))            ; PCM
      (insert (bindat-pack 'u16 channels))
      (insert (bindat-pack 'u32 sample-rate))
      (insert (bindat-pack 'u32 (* sample-rate channels (/ bits 8))))
      (insert (bindat-pack 'u16 (* channels (/ bits 8))))
      (insert (bindat-pack 'u16 bits))
      ;; data subchunk
      (insert "data")
      (insert (bindat-pack 'u32 data-size))
      (insert pcm-bytes)
      (write-region (point-min) (point-max) out-file nil 'silent))))

;; ----------------------------------------------------------------------
;; Menu Transient
;; ----------------------------------------------------------------------

(transient-define-prefix assistant-menu ()
  "Menu para Assistant TTS."
  [["Falar"
    ("r" "Região"      assistant-speak-region)
    ("p" "Parágrafo"   assistant-speak-paragraph)
    ("l" "Linha"       assistant-speak-line)
    ("b" "Buffer"      assistant-speak-buffer)]
   ["Reprodução"
    ("a" "Tocar último" assistant-play-last)
    ("c" "Cancelar"     assistant-cancel)]
   ["Servidor"
    ("s" "Iniciar servidor" assistant-server-start)
    ("h" "Verificar saúde"  assistant-check-health)]
   ["Configurações"
    ("v" "Voz (system prompt)"
     (lambda () (interactive)
       (setq assistant-system-prompt
             (read-string "System prompt: " assistant-system-prompt))))
    ("u" "URL da API"
     (lambda () (interactive)
       (setq assistant-api-url
             (read-string "URL: " assistant-api-url))))
    ("m" "Modelo"
     (lambda () (interactive)
       (setq assistant-model
             (read-string "Modelo: " assistant-model))))]])

;; ----------------------------------------------------------------------
;; Modo menor global
;; ----------------------------------------------------------------------

(defvar assistant-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t s") #'assistant-speak-region)
    (define-key map (kbd "C-c t p") #'assistant-speak-paragraph)
    (define-key map (kbd "C-c t l") #'assistant-speak-line)
    (define-key map (kbd "C-c t b") #'assistant-speak-buffer)
    (define-key map (kbd "C-c t a") #'assistant-play-last)
    (define-key map (kbd "C-c t c") #'assistant-cancel)
    (define-key map (kbd "C-c t m") #'assistant-menu)
    (define-key map (kbd "C-c t S") #'assistant-server-start)
    (define-key map (kbd "C-c t h") #'assistant-check-health)
    map)
  "Mapa de teclas para `assistant-mode'.")

;;;###autoload
(define-minor-mode assistant-mode
  "Modo menor global para TTS via API LFM Audio.
Atalhos sob C-c t."
  :lighter (:eval assistant--mode-line-string)
  :keymap assistant-mode-map
  :global t
  (if assistant-mode
      (message "Assistant mode ativado")
    (assistant-cancel)
    (message "Assistant mode desativado")))

;; ----------------------------------------------------------------------
;; Integração opcional com whisper-client
;; ----------------------------------------------------------------------

(declare-function whisper-client-db-save "whisper-client")
(defvar whisper-client-db-connection)

(defun assistant-log-to-whisper-history (text)
  "Registra geração TTS no histórico do whisper-client."
  (when (and (featurep 'whisper-client)
             (fboundp 'whisper-client-db-save)
             (boundp 'whisper-client-db-connection)
             whisper-client-db-connection
             assistant--last-output-file)
    (let ((job-id (format "tts-%d" (time-convert nil 'integer))))
      (whisper-client-db-save job-id
                              "tts-session"
                              text
                              "tts"
                              (secure-hash 'md5 text)
                              "completed"))))

(defvar assistant-after-finish-hook nil
  "Hook executado após geração TTS bem-sucedida.")

(add-hook 'assistant-after-finish-hook #'assistant-log-to-whisper-history)

(provide 'assistant)

;;; assistant.el ends here

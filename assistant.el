;;; assistant.el --- LFM 2.5 Audio TTS via HTTP API (streaming) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Seu Nome
;; Author: Seu Nome <voce@exemplo.com>
;; Version: 1.3.0
;; Package-Requires: ((emacs "28.1") (transient "0.4") (seq "2.24"))
;; Keywords: multimedia, tts, speech

;;; Commentary:
;; Cliente Emacs para o servidor LFM Audio (llama-liquid-audio-server).
;; Envia texto e reproduz áudio gerado via SSE.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'seq)
(require 'transient)
(eval-when-compile (require 'subr-x))

;; ----------------------------------------------------------------------
;; Customização
;; ----------------------------------------------------------------------

(defgroup assistant nil
  "Text-to-Speech via LFM Audio API."
  :group 'multimedia
  :prefix "assistant-")

(defcustom assistant-api-url "http://localhost:8080"
  "URL base do servidor LFM Audio."
  :type 'string)

(defcustom assistant-model "LFM2.5-Audio-1.5B-Q4_0"
  "Nome do modelo usado na API."
  :type 'string)

(defcustom assistant-temperature 0.0
  "Temperatura para geração (0.0 = determinístico)."
  :type 'float)

(defcustom assistant-system-prompt "Perform TTS. Use the US female voice."
  "Prompt de sistema enviado na requisição."
  :type 'string)

(defcustom assistant-sample-rate 24000
  "Taxa de amostragem esperada do áudio (Hz)."
  :type 'integer)

(defcustom assistant-output-dir (expand-file-name "assistant-output" (getenv "HOME"))
  "Diretório onde salvar os arquivos de áudio gerados."
  :type 'directory)

(defcustom assistant-playback-command nil
  "Comando externo para tocar WAV.
Se nil, tenta detectar automaticamente (ffplay, aplay, play) ou usa Emacs."
  :type '(choice (const :tag "Auto-detectar" nil)
                 (string :tag "Comando customizado")))

(defcustom assistant-notify-on-finish t
  "Mostrar mensagem quando a geração terminar."
  :type 'boolean)

(defcustom assistant-keep-output t
  "Se não-nil, não apaga os arquivos gerados após tocar."
  :type 'boolean)

(defcustom assistant-mode-line-format " A"
  "String exibida no mode-line durante geração."
  :type 'string)

(defcustom assistant-server-binary "/home/synbian/rbin/llama-liquid-audio-server"
  "Caminho para o binário do servidor (usado por `assistant-server-start')."
  :type 'file)

(defcustom assistant-ckpt-dir "/home/synbian/git/wget/AI/Models/LFM"
  "Diretório com os arquivos do modelo."
  :type 'directory)

(defcustom assistant-model-file "LFM2.5-Audio-1.5B-Q4_0.gguf"
  "Arquivo principal do modelo."
  :type 'string)

(defcustom assistant-mmproj-file "mmproj-LFM2.5-Audio-1.5B-Q4_0.gguf"
  "Arquivo do projetor multimodal."
  :type 'string)

(defcustom assistant-vocoder-file "vocoder-LFM2.5-Audio-1.5B-Q4_0.gguf"
  "Arquivo do vocoder."
  :type 'string)

(defcustom assistant-tokenizer-file "tokenizer-LFM2.5-Audio-1.5B-Q4_0.gguf"
  "Arquivo do tokenizador de speaker."
  :type 'string)

(defcustom assistant-use-steam-run nil
  "Prefixa o comando do servidor com `steam-run'."
  :type 'boolean)

(defcustom assistant-extra-server-args ""
  "Argumentos extras para o binário do servidor."
  :type 'string)

;; ----------------------------------------------------------------------
;; Estado interno e buffer de debug
;; ----------------------------------------------------------------------

(defvar assistant--active-process nil
  "Processo de rede ativo (conexão HTTP/SSE).")

(defvar assistant--audio-buffer ""
  "String unibyte acumuladora dos bytes PCM decodificados.")

(defvar assistant--last-output-file nil
  "Caminho do último arquivo WAV gerado com sucesso.")

(defvar assistant--mode-line-string ""
  "String atual do mode-line.")

(defvar assistant--response-buffer nil
  "Buffer temporário para resposta HTTP.")

(defvar assistant--raw-response-buffer nil
  "Buffer para armazenar toda a resposta crua (para debug).")

(defvar assistant--chunks-received 0
  "Contador de chunks SSE processados.")

(defvar assistant--headers-skipped nil
  "Flag indicando se os cabeçalhos HTTP já foram ignorados.")

(defvar assistant--debug-buffer "*assistant-debug*"
  "Nome do buffer para mensagens de debug.")

(defun assistant--debug (format &rest args)
  "Loga mensagem no buffer de debug."
  (with-current-buffer (get-buffer-create assistant--debug-buffer)
    (goto-char (point-max))
    (insert (apply #'format (concat format "\n") args))
    (let ((win (get-buffer-window (current-buffer))))
      (when win (set-window-point win (point-max))))))

(defun assistant--ensure-output-dir ()
  "Cria o diretório de saída se não existir, com logs."
  (let ((dir (expand-file-name assistant-output-dir)))
    (unless (file-directory-p dir)
      (condition-case err
          (progn
            (make-directory dir t)
            (assistant--debug "Diretório criado: %s" dir)
            (message "Diretório %s criado." dir))
        (error
         (assistant--debug "Erro ao criar diretório %s: %s" dir err)
         (message "Erro ao criar diretório %s: %s" dir err))))
    dir))

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
      (insert "RIFF")
      (insert (bindat-pack 'u32 (+ 36 data-size)))
      (insert "WAVE")
      (insert "fmt ")
      (insert (bindat-pack 'u32 16))           ; subchunk size (PCM)
      (insert (bindat-pack 'u16 1))            ; audio format (1 = PCM)
      (insert (bindat-pack 'u16 channels))
      (insert (bindat-pack 'u32 sample-rate))
      (insert (bindat-pack 'u32 (* sample-rate channels (/ bits 8)))) ; byte rate
      (insert (bindat-pack 'u16 (* channels (/ bits 8)))) ; block align
      (insert (bindat-pack 'u16 bits))
      (insert "data")
      (insert (bindat-pack 'u32 data-size))
      (insert pcm-bytes)
      (write-region (point-min) (point-max) out-file nil 'silent))))

;; ----------------------------------------------------------------------
;; Processamento SSE
;; ----------------------------------------------------------------------

(defun assistant--process-sse-data (data-str)
  "Extrai e decodifica audio_chunk de uma string 'data: ...'."
  (assistant--debug "SSE data: %s" (substring data-str 0 (min 200 (length data-str))))
  (when (string-match "^data: \\(.*\\)" data-str)
    (let* ((json-str (match-string 1 data-str))
           (json-obj (ignore-errors (json-parse-string json-str :object-type 'alist))))
      (when json-obj
        (let ((choices (cdr (assq 'choices json-obj)))
              (delta (cdr (assq 'delta (elt choices 0))))
              (audio (cdr (assq 'audio_chunk delta))))
          (when audio
            (let ((data (cdr (assq 'data audio))))
              (when data
                (cl-incf assistant--chunks-received)
                (assistant--debug "Chunk #%d, base64 length: %d" assistant--chunks-received (length data))
                (condition-case err
                    (base64-decode-string data t)
                  (error
                   (assistant--debug "Erro decodificando base64: %s" err)
                   nil))))))))))

(defun assistant--filter (proc string)
  "Filtro para processar dados recebidos do servidor."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      ;; Salva resposta crua para debug
      (when assistant--raw-response-buffer
        (with-current-buffer assistant--raw-response-buffer
          (goto-char (point-max))
          (insert string)))
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))
      ;; Pular cabeçalhos HTTP (procura por \r\n\r\n)
      (unless assistant--headers-skipped
        (when (re-search-forward "\r\n\r\n" nil t)
          (delete-region (point-min) (point))
          (setq assistant--headers-skipped t)
          (assistant--debug "Cabeçalhos HTTP ignorados. Início do corpo: %s"
                            (buffer-substring (point-min) (min 200 (point-max))))))
      ;; Processar eventos SSE (separadores: \n\n, \r\n\r\n, etc.)
      (while (re-search-forward "\n\n+\\|\r\n\r\n+" nil t)
        (let ((chunk (buffer-substring (point-min) (match-beginning 0))))
          (delete-region (point-min) (match-end 0))
          (unless (string-blank-p chunk)
            (let ((pcm-bytes (assistant--process-sse-data chunk)))
              (when pcm-bytes
                (setq assistant--audio-buffer
                      (concat assistant--audio-buffer pcm-bytes))))))))))

(defun assistant--sentinel (proc event)
  "Sentinel executado ao final da conexão."
  (assistant--debug "Sentinel chamado: %s, status: %s, código: %s"
                    event (process-status proc) (process-exit-status proc))
  (when (memq (process-status proc) '(exit signal))
    (setq assistant--active-process nil)
    (setq assistant--mode-line-string "")
    (force-mode-line-update t)
    (let ((text (process-get proc 'assistant-text)))
      (assistant--debug "Chunks recebidos: %d, tamanho PCM: %d bytes"
                        assistant--chunks-received (length assistant--audio-buffer))
      ;; Garante criação do diretório de saída
      (let ((out-dir (assistant--ensure-output-dir)))
        (let* ((timestamp (format-time-string "%Y%m%d-%H%M%S"))
               (base-name (concat "tts-" timestamp))
               (raw-file (expand-file-name (concat base-name ".pcm") out-dir))
               (wav-file (expand-file-name (concat base-name ".wav") out-dir))
               (resp-file (expand-file-name (concat base-name "-response.txt") out-dir)))
          ;; Salvar resposta crua (para debug)
          (when assistant--raw-response-buffer
            (with-current-buffer assistant--raw-response-buffer
              (write-region (point-min) (point-max) resp-file nil 'silent))
            (assistant--debug "Resposta crua salva em %s" resp-file))
          ;; Salvar PCM bruto (mesmo que vazio)
          (with-temp-file raw-file
            (set-buffer-multibyte nil)
            (insert assistant--audio-buffer))
          (assistant--debug "PCM bruto salvo em %s (%d bytes)" raw-file (length assistant--audio-buffer))
          (if (> (length assistant--audio-buffer) 0)
              (progn
                (assistant--pcm-to-wav assistant--audio-buffer wav-file)
                (assistant--debug "WAV salvo em %s" wav-file)
                (setq assistant--last-output-file wav-file)
                (when assistant-notify-on-finish
                  (message "TTS concluído: %s" wav-file))
                (assistant--play-file wav-file)
                (run-hook-with-args 'assistant-after-finish-hook text))
            (message "Nenhum dado PCM recebido. Verifique %s e %s" raw-file resp-file))
          (unless assistant-keep-output
            (run-with-timer 10 nil (lambda (f) (ignore-errors (delete-file f))) wav-file)
            (run-with-timer 10 nil (lambda (f) (ignore-errors (delete-file f))) raw-file)
            (run-with-timer 10 nil (lambda (f) (ignore-errors (delete-file f))) resp-file)))))
    ;; Resetar estado
    (setq assistant--audio-buffer "")
    (setq assistant--chunks-received 0)
    (setq assistant--headers-skipped nil)
    (when assistant--raw-response-buffer
      (kill-buffer assistant--raw-response-buffer)
      (setq assistant--raw-response-buffer nil))
    (when (buffer-live-p assistant--response-buffer)
      (kill-buffer assistant--response-buffer))))

;; ----------------------------------------------------------------------
;; Requisição HTTP / SSE
;; ----------------------------------------------------------------------

(defun assistant--request-tts (text)
  "Inicia requisição SSE para gerar TTS a partir de TEXT."
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
    (assistant--debug "Enviando requisição para %s:%d" host port)
    ;; Buffer para armazenar toda a resposta crua (útil para debug)
    (setq assistant--raw-response-buffer (generate-new-buffer " *assistant-raw-response*"))
    (condition-case err
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
          (message "Gerando TTS..."))
      (error
       (message "Erro ao conectar ao servidor: %s" (error-message-string err))
       (assistant--debug "Erro open-network-stream: %s" err)
       (when assistant--raw-response-buffer
         (kill-buffer assistant--raw-response-buffer))
       (setq assistant--raw-response-buffer nil)))))

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
    ("o" "Diretório de saída"
     (lambda () (interactive)
       (setq assistant-output-dir
             (read-directory-name "Diretório: " assistant-output-dir))))]])

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

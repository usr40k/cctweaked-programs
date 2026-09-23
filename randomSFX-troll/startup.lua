-- randomSFX
-- Usage:
--   randomSFX install   -> downloads all sound files
--   randomSFX           -> plays a random sound on first speaker

local args = {...}

-- List of files in the repo
local files = {
  "new-999-social-credit-siren.dfpwm",
  "new-amoogus.dfpwm",
  "new-autobots-transform-and-roll-out.dfpwm",
  "new-auughhh.dfpwm",
  "new-bad-to-the-bone-meme.dfpwm",
  "new-bogos-binted.dfpwm",
  "new-bone-crack.dfpwm",
  "new-bonk_7zPAD7C.dfpwm",
  "new-boop.dfpwm",
  "new-cartoon-running.dfpwm",
  "new-chase_QnUxJTk.dfpwm",
  "new-dry-fart.dfpwm",
  "new-explosion-meme_dTCfAHs.dfpwm",
  "new-loading-lost-connection-green-screen-with-sound-effect-2_K8HORkT.dfpwm",
  "new-metal-pipe-clang.dfpwm",
  "new-mlg-airhorn.dfpwm",
  "new-movie_1.dfpwm",
  "new-musica-elevador-short.dfpwm",
  "new-ny-video-online-audio-converter.dfpwm",
  "new-outro-song_oqu8zAg.dfpwm",
  "new-photos-printed.dfpwm",
  "new-rehehehe.dfpwm",
  "new-rizz-sound-effect.dfpwm",
  "new-saja-boys-soda-pop.dfpwm",
  "new-skedaddle.dfpwm",
  "new-smoke-detector-beep.dfpwm",
  "new-snore-mimimimimimi.dfpwm",
  "new-thx.dfpwm",
  "new-tindeck_1.dfpwm",
  "new-tokyo_drift.dfpwm",
  "new-tuco-get-out.dfpwm",
  "new-vine-boom.dfpwm",
  "new-wild-thornberrys-donnie.dfpwm",
  "new-yeah-boiii-i-i-i.dfpwm",
  "startup.lua",
}

-- Base URL of your repo
local baseURL = "https://raw.githubusercontent.com/usr40k/cctweaked-programs/main/randomSFX-troll/"

if args[1] == "install" then
  print("Downloading sound files...")
  for _, fname in ipairs(files) do
    local url = baseURL .. fname
    print("Downloading " .. fname)
    shell.run("wget " .. url .. " " .. fname)
  end
  print("All files downloaded.")
else
  -- Find first speaker
  local speaker = peripheral.find("speaker")
  if not speaker then
    error("No speaker peripheral found!")
  end
  while true do
    -- Pick a random file
    local choice = files[math.random(#files)]
    print("Playing " .. choice)

    -- Open file and stream to speaker
    local decoder = require("cc.audio.dfpwm").make_decoder()
    local f = assert(io.open(choice, "rb"))
    for chunk in f:lines(16 * 1024) do
      local buffer = decoder(chunk)
      while not speaker.playAudio(buffer) do
        os.pullEvent("speaker_audio_empty")
      end
    end
    f:close()
    os.sleep(60)
  end
end

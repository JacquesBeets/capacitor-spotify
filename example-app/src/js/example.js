import { Spotify } from 'capacitor-spotify';

window.testEcho = () => {
    const inputValue = document.getElementById("echoInput").value;
    Spotify.echo({ value: inputValue })
}

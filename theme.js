// Dark mode: tersimpan di localStorage, tombol dengan id="th"
document.documentElement.dataset.theme=localStorage.theme||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');
addEventListener('DOMContentLoaded',()=>{const b=document.getElementById('th');if(!b)return;
 const sync=()=>b.textContent=document.documentElement.dataset.theme=='dark'?'☀️':'🌙';sync();
 b.onclick=()=>{const d=document.documentElement.dataset.theme=='dark'?'light':'dark';document.documentElement.dataset.theme=localStorage.theme=d;sync()}});

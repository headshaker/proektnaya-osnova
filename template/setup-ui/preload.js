'use strict'

const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('projectSetup', Object.freeze({
  getDefaults: () => ipcRenderer.invoke('setup:get-defaults'),
  preview: payload => ipcRenderer.invoke('setup:preview', payload),
  apply: payload => ipcRenderer.invoke('setup:apply', payload),
  openHome: () => ipcRenderer.invoke('setup:open-home')
}))
